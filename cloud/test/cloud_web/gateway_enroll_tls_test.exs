defmodule CloudWeb.GatewayEnrollTLSTest do
  # enrolment over a real Bandit https listener on a random port, with the dev pki for
  # the server and self-signed gateway certificates, as a box presents them
  use CloudWeb.ChannelCase, async: false

  import Cloud.Fixtures

  alias Cloud.Sites
  alias Cloud.Sites.GatewayEnrollments

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    {:ok, pki} = Cloud.DevPKI.generate(dir)
    %{tenant: tenant, admin: admin} = org!()
    site = site!(tenant, admin)

    for name <- ~w(a b c) do
      {:ok, _} = Cloud.DevPKI.self_signed_client(name, cert(dir, name), key(dir, name))
    end

    {:ok, _} =
      Cloud.DevPKI.self_signed_client("old", cert(dir, "old"), key(dir, "old"),
        not_before: ~U[2020-01-01 00:00:00Z],
        not_after: ~U[2021-01-01 00:00:00Z]
      )

    server =
      start_supervised!(
        {Bandit,
         plug: CloudWeb.GatewayEndpoint,
         scheme: :https,
         ip: {127, 0, 0, 1},
         port: 0,
         certfile: pki.server_cert,
         keyfile: pki.server_key,
         startup_log: false,
         thousand_island_options: [
           transport_options: CloudWeb.GatewayTLS.transport_options(pki.ca_cert)
         ]}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    previous = Application.get_env(:cloud, :gateway_enrollment)

    Application.put_env(:cloud, :gateway_enrollment,
      url: "https://localhost:#{port}",
      ca_certfile: pki.ca_cert,
      server_name: "localhost"
    )

    on_exit(fn -> restore(:gateway_enrollment, previous) end)

    %{site: site, admin: admin, tenant: tenant, port: port, pki: pki, dir: dir}
  end

  defp restore(key, nil), do: Application.delete_env(:cloud, key)
  defp restore(key, value), do: Application.put_env(:cloud, key, value)

  defp cert(dir, name), do: Path.join(dir, name <> ".pem")
  defp key(dir, name), do: Path.join(dir, name <> ".key")

  defp fingerprint(ctx, name) do
    {:ok, fp} = Cloud.DevPKI.pem_fingerprint(cert(ctx.dir, name))
    fp
  end

  defp tls_connect(ctx, name) do
    :ssl.connect(
      ~c"127.0.0.1",
      ctx.port,
      [
        certfile: cert(ctx.dir, name),
        keyfile: key(ctx.dir, name),
        cacertfile: ctx.pki.ca_cert,
        verify: :verify_peer,
        server_name_indication: ~c"localhost",
        versions: [:"tlsv1.3", :"tlsv1.2"],
        active: false,
        mode: :binary
      ],
      5000
    )
  end

  # one http/1.1 request on a fresh tls session, read until the server closes
  defp request(ctx, name, head, body) do
    with {:ok, socket} <- tls_connect(ctx, name) do
      :ok = :ssl.send(socket, [head, body])
      result = read_all(socket, "")
      :ssl.close(socket)
      result
    end
  end

  defp read_all(socket, acc) do
    case :ssl.recv(socket, 0, 5000) do
      {:ok, data} -> read_all(socket, acc <> data)
      {:error, :closed} -> {:ok, acc}
      {:error, reason} -> if acc == "", do: {:error, reason}, else: {:ok, acc}
    end
  end

  defp enroll(ctx, name, body) do
    body = if is_binary(body), do: body, else: JSON.encode!(body)

    head =
      "POST /gateway/enroll HTTP/1.1\r\nhost: localhost\r\ncontent-type: application/json\r\n" <>
        "content-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n"

    case request(ctx, name, head, body) do
      {:ok, response} ->
        [status_line | _] = String.split(response, "\r\n", parts: 2)
        [_, payload] = String.split(response, "\r\n\r\n", parts: 2)
        ["HTTP/1.1", status | _] = String.split(status_line, " ")
        {String.to_integer(status), JSON.decode!(payload)}

      error ->
        error
    end
  end

  defp websocket_status(ctx, name) do
    head =
      "GET /gateway/socket/websocket?vsn=2.0.0 HTTP/1.1\r\nhost: localhost\r\n" <>
        "upgrade: websocket\r\nconnection: Upgrade\r\n" <>
        "sec-websocket-key: #{Base.encode64(:crypto.strong_rand_bytes(16))}\r\n" <>
        "sec-websocket-version: 13\r\n\r\n"

    {:ok, socket} = tls_connect(ctx, name)
    :ok = :ssl.send(socket, head)
    {:ok, data} = :ssl.recv(socket, 0, 5000)
    :ssl.close(socket)
    [_, status | _] = String.split(data, " ", parts: 3)
    String.to_integer(status)
  end

  defp audit_actions(ctx) do
    Cloud.Audit.audit_chain!(tenant: ctx.tenant.id, authorize?: false)
    |> Enum.map(& &1.entry["action"])
  end

  test "a code enrols the certificate of the tls session and answers the settings", ctx do
    {code, enrollment} = enrollment!(ctx.site, ctx.admin)

    # a fingerprint in the body is ignored, only the session's certificate counts
    assert {200, answer} =
             enroll(ctx, "a", %{"code" => code, "fingerprint" => fingerprint(ctx, "b")})

    assert answer["site_id"] == ctx.site.id
    assert answer["uplink_url"] == "wss://localhost:#{ctx.port}/gateway/socket/websocket"
    assert answer["server_name"] == "localhost"
    assert answer["ca_pem"] == File.read!(ctx.pki.ca_cert) |> normalise_pem()

    assert answer["public_keys"] == %{
             Cloud.Signer.key_id() => Base.url_encode64(Cloud.Signer.public_key(), padding: false)
           }

    site = Sites.get_site!(ctx.site.id, authorize?: false)
    assert site.gateway_cert_fingerprint == fingerprint(ctx, "a")

    [used] = Sites.list_gateway_enrollments!(actor: ctx.admin, tenant: ctx.tenant)
    assert used.id == enrollment.id
    assert used.used_at
    assert used.remote_ip == "127.0.0.1"
    assert "gateway_enrollment.used" in audit_actions(ctx)

    # the enrolled certificate can open the gateway socket, another one cannot
    assert websocket_status(ctx, "a") == 101
    assert websocket_status(ctx, "b") == 403

    # the code is spent
    assert {403, %{"error" => "invalid_code"}} = enroll(ctx, "b", %{"code" => code})
  end

  test "expired, cancelled, unknown and malformed codes get the same refusal", ctx do
    {expired, enrollment} = enrollment!(ctx.site, ctx.admin)
    expire_enrollment!(enrollment)
    assert {403, %{"error" => "invalid_code"}} = enroll(ctx, "a", %{"code" => expired})

    {cancelled, enrollment} = enrollment!(ctx.site, ctx.admin)
    Sites.cancel_gateway_enrollment!(enrollment, actor: ctx.admin, tenant: ctx.tenant)
    assert {403, %{"error" => "invalid_code"}} = enroll(ctx, "a", %{"code" => cancelled})

    {unknown, _} = GatewayEnrollments.new_code()
    assert {403, %{"error" => "invalid_code"}} = enroll(ctx, "a", %{"code" => unknown})
    assert {403, %{"error" => "invalid_code"}} = enroll(ctx, "a", %{"code" => "nope"})

    assert {400, %{"error" => "bad_request"}} = enroll(ctx, "a", "not json")
    assert {400, %{"error" => "bad_request"}} = enroll(ctx, "a", %{"code" => 7})

    assert Sites.get_site!(ctx.site.id, authorize?: false).gateway_cert_fingerprint == nil
  end

  test "re-enrolling replaces the pinned box and disconnects it", ctx do
    {code, _} = enrollment!(ctx.site, ctx.admin)
    assert {200, _} = enroll(ctx, "a", %{"code" => code})
    assert websocket_status(ctx, "a") == 101

    CloudWeb.GatewayEndpoint.subscribe("gateway_socket:" <> ctx.site.id)

    {code, enrollment} = enrollment!(ctx.site, ctx.admin)
    assert enrollment.replaced_fingerprint == fingerprint(ctx, "a")
    assert {200, _} = enroll(ctx, "b", %{"code" => code})

    assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}

    assert Sites.get_site!(ctx.site.id, authorize?: false).gateway_cert_fingerprint ==
             fingerprint(ctx, "b")

    # the old box is locked out, the new one is in
    assert websocket_status(ctx, "a") == 403
    assert websocket_status(ctx, "b") == 101

    used =
      Cloud.Audit.audit_chain!(tenant: ctx.tenant.id, authorize?: false)
      |> Enum.map(& &1.entry)
      |> Enum.filter(&(&1["action"] == "gateway_enrollment.used"))
      |> List.last()

    assert used["replaced_fingerprint"] == fingerprint(ctx, "a")
    assert used["gateway_cert_fingerprint"] == fingerprint(ctx, "b")
  end

  test "a certificate another site pins cannot enrol here", ctx do
    other = site!(ctx.tenant, ctx.admin)
    {code, _} = enrollment!(other, ctx.admin)
    assert {200, _} = enroll(ctx, "a", %{"code" => code})

    {code, _} = enrollment!(ctx.site, ctx.admin)
    assert {409, %{"error" => "certificate_in_use"}} = enroll(ctx, "a", %{"code" => code})
    assert {200, _} = enroll(ctx, "c", %{"code" => code})
  end

  test "an expired self-signed certificate never gets past the handshake", ctx do
    {code, _} = enrollment!(ctx.site, ctx.admin)

    case enroll(ctx, "old", %{"code" => code}) do
      {:error, reason} -> assert inspect(reason) =~ "expired"
      {:ok, ""} -> :ok
    end

    assert {200, _} = enroll(ctx, "a", %{"code" => code})
  end

  test "attempts are rate limited per ip", ctx do
    previous = Application.get_env(:cloud, CloudWeb.GatewayEnroll)
    # a window of its own, so the counter starts at zero
    window = :timer.minutes(10) + System.unique_integer([:positive])
    Application.put_env(:cloud, CloudWeb.GatewayEnroll, rate_limit: {2, window})
    on_exit(fn -> restore(CloudWeb.GatewayEnroll, previous) end)

    {code, _} = enrollment!(ctx.site, ctx.admin)
    assert {403, _} = enroll(ctx, "a", %{"code" => "guess-1"})
    assert {403, _} = enroll(ctx, "a", %{"code" => "guess-2"})
    # even the right code is refused once the ip is over the limit
    assert {429, %{"error" => "rate_limited"}} = enroll(ctx, "a", %{"code" => code})
    assert Sites.get_site!(ctx.site.id, authorize?: false).gateway_cert_fingerprint == nil
  end

  defp normalise_pem(pem) do
    [{:Certificate, der, _} | _] = :public_key.pem_decode(pem)
    :public_key.pem_encode([{:Certificate, der, :not_encrypted}])
  end
end
