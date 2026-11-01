defmodule Gateway.EnrollTest do
  # runs Gateway.Enroll against a local tls server standing in for the cloud's gateway
  # endpoint: it accepts self-signed client certificates as the cloud does, sends its
  # ca along with its certificate, and answers the enrolment request with a canned reply
  use ExUnit.Case, async: true

  import Gateway.TestSupport, only: [tmp_dir: 1]

  alias Breakline.GatewayIdentity
  alias Gateway.Enroll

  @key [key: {:namedCurve, :secp256r1}, digest: :sha256]

  setup do
    dir = tmp_dir("enroll")
    pki = pki(["localhost"])
    %{dir: dir, pki: pki, pin: GatewayIdentity.spki_sha256(pki.root)}
  end

  # a server certificate for `names` and the root that signed it
  defp pki(names) do
    san = {:Extension, {2, 5, 29, 17}, false, Enum.map(names, &{:dNSName, ~c"#{&1}"})}

    data =
      :public_key.pkix_test_data(%{
        server_chain: %{root: @key, intermediates: [], peer: [{:extensions, [san]} | @key]},
        client_chain: %{root: @key, intermediates: [], peer: @key}
      })

    [root | _] = data.client_config[:cacerts]
    server = data.server_config |> Keyword.delete(:cacerts) |> Keyword.put(:cacerts, [root])
    %{server: server, root: root}
  end

  # one connection: records the client certificate and the request, then answers
  defp serve(pki, reply) do
    opts =
      pki.server ++
        [
          verify: :verify_peer,
          fail_if_no_peer_cert: true,
          verify_fun:
            {fn
               _, {:bad_cert, :selfsigned_peer}, s -> {:valid, s}
               _, {:bad_cert, reason}, _ -> {:fail, reason}
               _, {:extension, _}, s -> {:unknown, s}
               _, _valid, s -> {:valid, s}
             end, nil},
          versions: [:"tlsv1.3", :"tlsv1.2"],
          active: false,
          mode: :binary,
          reuseaddr: true
        ]

    {:ok, listen} = :ssl.listen(0, opts)
    {:ok, {_, port}} = :ssl.sockname(listen)
    test = self()

    pid =
      spawn_link(fn ->
        {:ok, socket} = :ssl.transport_accept(listen)

        case :ssl.handshake(socket, 5000) do
          {:ok, socket} ->
            {:ok, der} = :ssl.peercert(socket)
            request = read_request(socket, "")
            send(test, {:request, der, request})
            {status, body} = reply.(der)
            body = JSON.encode!(body)

            :ssl.send(socket, [
              "HTTP/1.1 #{status} x\r\ncontent-type: application/json\r\n",
              "content-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n",
              body
            ])

            :ssl.close(socket)

          error ->
            send(test, {:handshake, error})
        end

        :ssl.close(listen)
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    port
  end

  defp read_request(socket, acc) do
    with [head, body] <- :binary.split(acc, "\r\n\r\n"),
         [_, length] <- Regex.run(~r/content-length: (\d+)/i, head),
         true <- byte_size(body) >= String.to_integer(length) do
      {head, JSON.decode!(body)}
    else
      _ ->
        {:ok, data} = :ssl.recv(socket, 0, 5000)
        read_request(socket, acc <> data)
    end
  end

  defp answer(pki, overrides \\ %{}) do
    {pub, _} = Breakline.Command.generate_keypair()

    Map.merge(
      %{
        "site_id" => "site-1",
        "public_keys" => %{"cloud-1" => Base.url_encode64(pub, padding: false)},
        "ca_pem" => GatewayIdentity.cert_pem(pki.root),
        "uplink_url" => "wss://localhost:4011/gateway/socket/websocket",
        "server_name" => "localhost"
      },
      overrides
    )
  end

  defp mode(path), do: File.stat!(path).mode |> Bitwise.band(0o777)

  test "enrols with a pinned ca and writes the identity and the enrolment", ctx do
    port = serve(ctx.pki, fn _der -> {200, answer(ctx.pki)} end)
    url = "https://localhost:#{port}"

    assert {:ok, enrollment} = Enroll.run(url, "ABCD-EFGH", ctx.pin, ctx.dir)

    # the server saw the box's own certificate and the code, nothing else
    assert_receive {:request, der, {head, body}}
    assert head =~ "POST /gateway/enroll HTTP/1.1"
    assert body == %{"code" => "ABCD-EFGH"}
    assert :public_key.pkix_is_self_signed(der)

    p = Enroll.paths(ctx.dir)
    assert {:ok, identity} = GatewayIdentity.from_pem(File.read!(p.cert), File.read!(p.key))
    assert identity.cert_der == der
    assert mode(p.key) == 0o600
    assert mode(p.identity_dir) == 0o700

    assert enrollment["fingerprint"] == GatewayIdentity.fingerprint(der)
    assert enrollment["site_id"] == "site-1"
    assert enrollment["cloud_url"] == url
    assert {:ok, ^enrollment} = Enroll.read(ctx.dir)
    assert [{:Certificate, root, _}] = :public_key.pem_decode(File.read!(p.ca))
    assert root == ctx.pki.root

    # enrolling again keeps the box's key
    port = serve(ctx.pki, fn _der -> {200, answer(ctx.pki, %{"site_id" => "site-2"})} end)

    assert {:ok, %{"site_id" => "site-2"}} =
             Enroll.run("https://localhost:#{port}", "x", String.upcase(ctx.pin), ctx.dir)

    assert_receive {:request, ^der, _}
  end

  test "a wrong ca pin fails the handshake and writes no enrolment", ctx do
    port = serve(ctx.pki, fn _der -> {200, answer(ctx.pki)} end)
    other = GatewayIdentity.spki_sha256(pki(["localhost"]).root)

    assert {:error, {:tls, {:tls_alert, {:unknown_ca, _}}} = reason} =
             Enroll.run("https://localhost:#{port}", "code", other, ctx.dir)

    assert Enroll.format_error(reason) =~ "pinned ca"
    refute_received {:request, _, _}
    assert Enroll.read(ctx.dir) == :error
  end

  test "a server certificate for another name is refused", ctx do
    pki = pki(["cloud.example.com"])
    pin = GatewayIdentity.spki_sha256(pki.root)
    port = serve(pki, fn _der -> {200, answer(pki)} end)

    assert {:error, {:tls, _}} = Enroll.run("https://localhost:#{port}", "code", pin, ctx.dir)
    assert Enroll.read(ctx.dir) == :error
  end

  test "an answer whose ca does not match the pin is not saved", ctx do
    other = pki(["localhost"])

    port =
      serve(ctx.pki, fn _der ->
        {200, answer(ctx.pki, %{"ca_pem" => GatewayIdentity.cert_pem(other.root)})}
      end)

    assert {:error, {:bad_answer, why}} =
             Enroll.run("https://localhost:#{port}", "code", ctx.pin, ctx.dir)

    assert why =~ "does not match"
    assert Enroll.read(ctx.dir) == :error
  end

  test "the cloud's refusals come back readable", ctx do
    port = serve(ctx.pki, fn _der -> {403, %{"error" => "invalid_code"}} end)

    env = %{
      "BREAKLINE_ENROLL_URL" => "https://localhost:#{port}",
      "BREAKLINE_ENROLL_CODE" => "used-code",
      "BREAKLINE_ENROLL_CA_SHA256" => ctx.pin,
      "BREAKLINE_DATA_DIR" => ctx.dir
    }

    assert {:error, "enrolment failed: the code is wrong, used, cancelled or expired"} =
             Enroll.from_env(env)

    port = serve(ctx.pki, fn _der -> {200, answer(ctx.pki)} end)

    assert {:ok, "enrolled: site site-1, gateway certificate " <> _} =
             Enroll.from_env(%{env | "BREAKLINE_ENROLL_URL" => "https://localhost:#{port}"})
  end

  test "bad input is refused before anything is made", ctx do
    assert {:error, "enrolment failed: BREAKLINE_ENROLL_CODE, BREAKLINE_ENROLL_CA_SHA256 not set"} =
             Enroll.from_env(%{"BREAKLINE_ENROLL_URL" => "https://x"})

    assert {:error, :invalid_url} = Enroll.run("http://x:4011", "c", ctx.pin, ctx.dir)
    assert {:error, :invalid_pin} = Enroll.run("https://x:4011", "c", "abc", ctx.dir)
    assert {:error, :invalid_code} = Enroll.run("https://x:4011", "", ctx.pin, ctx.dir)
    refute File.exists?(Enroll.paths(ctx.dir).identity_dir)
  end

  test "a half-present identity is an error, never replaced", ctx do
    p = Enroll.paths(ctx.dir)
    File.mkdir_p!(p.identity_dir)
    File.write!(p.cert, "x")
    assert {:error, {:incomplete_identity, _}} = Enroll.ensure_identity(ctx.dir)
    assert File.read!(p.cert) == "x"
  end
end
