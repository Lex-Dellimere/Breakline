defmodule CloudWeb.GatewayEndpointTLSTest do
  # runs CloudWeb.GatewayEndpoint behind a real Bandit https listener with the
  # dev pki (openssl) and self-signed gateway certificates, to prove the client
  # certificate reaches the socket's connect_info.peer_data.ssl_cert, then joins
  # a channel over the wire
  use CloudWeb.ChannelCase, async: false

  import Cloud.Fixtures

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    {:ok, pki} = Cloud.DevPKI.generate(dir)
    %{tenant: tenant, admin: admin} = org!()
    site = site!(tenant, admin)

    {:ok, fingerprint} =
      Cloud.DevPKI.self_signed_client(site.id, Path.join(dir, "gw.pem"), Path.join(dir, "gw.key"))

    site = Cloud.Sites.assign_gateway!(site, fingerprint, authorize?: false)

    # a self-signed certificate that no site has pinned, and one the ca signed
    {:ok, _} =
      Cloud.DevPKI.self_signed_client(
        "stranger",
        Path.join(dir, "x.pem"),
        Path.join(dir, "x.key")
      )

    {:ok, _} =
      Cloud.DevPKI.issue_client(
        dir,
        "ca-signed",
        Path.join(dir, "c.pem"),
        Path.join(dir, "c.key")
      )

    # the same tls options as config/runtime.exs
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
    %{site: site, port: port, pki: pki, dir: dir}
  end

  defp tls_connect(ctx, client) do
    opts =
      [
        cacertfile: ctx.pki.ca_cert,
        verify: :verify_peer,
        server_name_indication: ~c"localhost",
        versions: [:"tlsv1.3", :"tlsv1.2"],
        active: false,
        mode: :binary
      ] ++ client

    :ssl.connect(~c"127.0.0.1", ctx.port, opts, 5000)
  end

  defp client_cert(ctx, name) do
    [certfile: Path.join(ctx.dir, name <> ".pem"), keyfile: Path.join(ctx.dir, name <> ".key")]
  end

  defp upgrade(socket) do
    key = Base.encode64(:crypto.strong_rand_bytes(16))

    :ok =
      :ssl.send(socket, [
        "GET /gateway/socket/websocket?vsn=2.0.0 HTTP/1.1\r\n",
        "Host: localhost\r\n",
        "Upgrade: websocket\r\n",
        "Connection: Upgrade\r\n",
        "Sec-WebSocket-Key: #{key}\r\n",
        "Sec-WebSocket-Version: 13\r\n\r\n"
      ])

    read_head(socket, "")
  end

  defp read_head(socket, acc) do
    case :binary.split(acc, "\r\n\r\n") do
      [head, rest] ->
        {:ok, head, rest}

      [_] ->
        case :ssl.recv(socket, 0, 5000) do
          {:ok, data} -> read_head(socket, acc <> data)
          error -> error
        end
    end
  end

  # one masked text frame, as a client must send it
  defp send_text(socket, text) do
    mask = :crypto.strong_rand_bytes(4)
    len = byte_size(text)

    header =
      cond do
        len < 126 -> <<0x81, 1::1, len::7>>
        len < 65_536 -> <<0x81, 1::1, 126::7, len::16>>
      end

    :ssl.send(socket, [header, mask, mask_bytes(text, mask)])
  end

  defp mask_bytes(data, <<a, b, c, d>>) do
    data
    |> :binary.bin_to_list()
    |> Enum.with_index()
    |> Enum.map(fn {byte, i} -> Bitwise.bxor(byte, elem({a, b, c, d}, rem(i, 4))) end)
    |> :binary.list_to_bin()
  end

  # one unmasked text frame from the server
  defp recv_text(socket, buffer) do
    case buffer do
      <<0x81, 0::1, 126::7, len::16, payload::binary-size(len), _::binary>> ->
        {:ok, payload}

      <<0x81, 0::1, len::7, payload::binary-size(len), _::binary>> when len < 126 ->
        {:ok, payload}

      _ ->
        case :ssl.recv(socket, 0, 5000) do
          {:ok, data} -> recv_text(socket, buffer <> data)
          error -> error
        end
    end
  end

  test "a pinned client certificate reaches the socket and can join", ctx do
    assert {:ok, socket} = tls_connect(ctx, client_cert(ctx, "gw"))
    assert {:ok, "HTTP/1.1 101" <> _, rest} = upgrade(socket)

    join =
      JSON.encode!([
        "1",
        "1",
        "gateway:" <> ctx.site.id,
        "phx_join",
        %{"hello" => %{"last_version" => 0, "audit" => %{"chain_id" => nil}}}
      ])

    :ok = send_text(socket, join)
    assert {:ok, reply} = recv_text(socket, rest)

    assert ["1", "1", "gateway:" <> _, "phx_reply", %{"status" => "ok", "response" => response}] =
             JSON.decode!(reply)

    assert %{"heartbeat_ms" => 30_000, "policy" => nil, "audit_ack" => nil} = response
    :ssl.close(socket)
  end

  test "a self-signed certificate that no site pins is refused at connect", ctx do
    assert {:ok, socket} = tls_connect(ctx, client_cert(ctx, "x"))
    assert {:ok, "HTTP/1.1 403" <> _, _} = upgrade(socket)
    :ssl.close(socket)
  end

  test "a certificate the ca signed still needs a pin", ctx do
    assert {:ok, socket} = tls_connect(ctx, client_cert(ctx, "c"))
    assert {:ok, "HTTP/1.1 403" <> _, _} = upgrade(socket)
    :ssl.close(socket)
  end

  test "no client certificate fails the tls handshake", ctx do
    case tls_connect(ctx, []) do
      {:error, reason} ->
        assert inspect(reason) =~ "certificate_required" or inspect(reason) =~ "handshake"

      # with tls 1.3 the client may finish first and see the server's alert on read
      {:ok, socket} ->
        assert {:error, reason} = upgrade(socket)
        assert inspect(reason) =~ "certificate_required"
    end
  end
end
