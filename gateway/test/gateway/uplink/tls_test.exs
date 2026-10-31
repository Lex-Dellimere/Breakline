defmodule Gateway.Uplink.TLSTest do
  # runs Gateway.Uplink.mint_opts/1 against a local tls server with throwaway
  # certificates from :public_key.pkix_test_data/1: the client must present its
  # certificate, trust only the given ca and check the server's name
  use ExUnit.Case, async: true

  import Gateway.TestSupport, only: [tmp_dir: 1]

  alias Gateway.Uplink

  # tls 1.3 needs a curve and digest it accepts, the defaults are older
  @key [key: {:namedCurve, :secp256r1}, digest: :sha256]

  setup do
    dir = tmp_dir("uplink-tls")
    pki = pki(dir, "a")
    other = pki(dir, "b")
    {:ok, listen, port} = listen(pki.server)
    on_exit(fn -> :ssl.close(listen) end)
    %{pki: pki, other: other, port: port, listen: listen}
  end

  # a server chain whose certificate is for localhost, a client chain, and pem
  # files for the client side
  defp pki(dir, name) do
    san = {:Extension, {2, 5, 29, 17}, false, [dNSName: ~c"localhost"]}

    data =
      :public_key.pkix_test_data(%{
        server_chain: %{root: @key, intermediates: [], peer: [{:extensions, [san]} | @key]},
        client_chain: %{root: @key, intermediates: [], peer: @key}
      })

    client = data.client_config
    {:ECPrivateKey, key_der} = client[:key]

    files = %{
      certfile:
        write_pem(dir, "#{name}-client.pem", [{:Certificate, client[:cert], :not_encrypted}]),
      keyfile: write_pem(dir, "#{name}-client.key", [{:ECPrivateKey, key_der, :not_encrypted}]),
      cacertfile:
        write_pem(
          dir,
          "#{name}-ca.pem",
          Enum.map(client[:cacerts], &{:Certificate, &1, :not_encrypted})
        )
    }

    %{server: data.server_config, client: files}
  end

  defp write_pem(dir, name, entries) do
    path = Path.join(dir, name)
    File.write!(path, :public_key.pem_encode(entries))
    path
  end

  defp listen(server_config) do
    opts =
      server_config ++
        [
          verify: :verify_peer,
          fail_if_no_peer_cert: true,
          versions: [:"tlsv1.3", :"tlsv1.2"],
          active: false,
          reuseaddr: true
        ]

    {:ok, listen} = :ssl.listen(0, opts)
    {:ok, {_, port}} = :ssl.sockname(listen)
    test = self()

    spawn_link(fn -> accept_loop(listen, test) end)
    {:ok, listen, port}
  end

  defp accept_loop(listen, test) do
    case :ssl.transport_accept(listen) do
      {:ok, socket} ->
        result = :ssl.handshake(socket, 5000)
        send(test, {:server_handshake, result})
        accept_loop(listen, test)

      {:error, _} ->
        :ok
    end
  end

  defp connect(host, port, files, extra \\ %{}) do
    opts = Uplink.mint_opts(Map.merge(files, Map.put(extra, :url, "wss://#{host}:#{port}/x")))
    Mint.HTTP.connect(:https, host, port, opts)
  end

  test "connects with the client certificate when the server's name matches", ctx do
    assert {:ok, conn} = connect("localhost", ctx.port, ctx.pki.client)
    assert_receive {:server_handshake, {:ok, socket}}, 5000

    # the server saw the gateway's certificate
    assert {:ok, _der} = :ssl.peercert(socket)
    Mint.HTTP.close(conn)
  end

  test "server_name is the name checked, whatever address is dialled", ctx do
    assert {:ok, conn} =
             connect("127.0.0.1", ctx.port, ctx.pki.client, %{server_name: "localhost"})

    Mint.HTTP.close(conn)
  end

  test "a server certificate for another name is refused", ctx do
    assert {:error, %Mint.TransportError{reason: reason}} =
             connect("localhost", ctx.port, ctx.pki.client, %{server_name: "cloud.example.com"})

    assert inspect(reason) =~ "hostname_check_failed"
  end

  test "a server certificate from another ca is refused", ctx do
    files = %{ctx.pki.client | cacertfile: ctx.other.client.cacertfile}

    assert {:error, %Mint.TransportError{reason: reason}} =
             connect("localhost", ctx.port, files)

    assert inspect(reason) =~ "unknown_ca"
  end
end
