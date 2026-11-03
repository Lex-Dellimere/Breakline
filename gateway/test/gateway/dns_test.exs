defmodule Gateway.DNSTest do
  # the snapshot lives in :persistent_term, so these tests share global state
  use ExUnit.Case, async: false

  require Record

  alias Gateway.DNS.Snapshot

  @hrl "kernel/src/inet_dns.hrl"
  Record.defrecordp(:dns_rec, Record.extract(:dns_rec, from_lib: @hrl))
  Record.defrecordp(:dns_header, Record.extract(:dns_header, from_lib: @hrl))
  Record.defrecordp(:dns_query, Record.extract(:dns_query, from_lib: @hrl))
  Record.defrecordp(:dns_rr, Record.extract(:dns_rr, from_lib: @hrl))

  @localhost {127, 0, 0, 1}

  # canned upstream answers by lowercase qname
  @answers %{
    "example.com" => [{:a, "example.com", {93, 184, 216, 34}, 300}],
    "relay-1.net.anydesk.com" => [
      {:a, "relay-1.net.anydesk.com", {10, 0, 0, 1}, 60},
      {:aaaa, "relay-1.net.anydesk.com", {0xFD00, 0, 0, 0, 0, 0, 0, 1}, 60}
    ],
    "instance-x.screenconnect.com" => [{:a, "instance-x.screenconnect.com", {10, 0, 0, 2}, 30}],
    "support.msp.example" => [
      {:cname, "support.msp.example", "instance-x.screenconnect.com", 300},
      {:a, "instance-x.screenconnect.com", {10, 0, 0, 2}, 30}
    ],
    "alias.client.example" => [
      {:cname, "alias.client.example", "rmm.client.example", 300},
      {:a, "rmm.client.example", {10, 0, 0, 3}, 120}
    ],
    "rmm.client.example" => [{:a, "rmm.client.example", {10, 0, 0, 3}, 120}],
    "big.example" => [{:a, "big.example", {10, 0, 0, 4}, 50}],
    "dns.google" => [{:a, "dns.google", {8, 8, 8, 8}, 300}]
  }

  setup do
    Snapshot.clear()
    on_exit(&Snapshot.clear/0)

    upstream = start_upstream(self(), :answer)
    dns = start_dns([upstream])
    %{port: Gateway.DNS.port(dns), dns: dns, upstream: upstream}
  end

  describe "pass-through" do
    test "a plain name gets the upstream bytes unchanged", %{port: port} do
      reply = udp_query(port, "example.com", :a, 4242)
      assert_receive {:upstream_sent, sent}
      assert reply == sent
      assert {:a, {93, 184, 216, 34}} in answers(reply)
      assert id(reply) == 4242
    end

    test "tcp queries work", %{port: port} do
      reply = tcp_query(port, "example.com", :a, 7)
      assert_receive {:upstream_sent, sent}
      assert reply == sent
      assert id(reply) == 7
    end

    test "a truncated udp answer is retried over tcp", %{port: port} do
      reply = udp_query(port, "big.example", :a, 99)
      assert_receive {:upstream_tcp, _query}
      assert {:a, {10, 0, 0, 4}} in answers(reply)
      refute truncated?(reply)
    end

    test "no events or ip records for ordinary names", %{port: port} do
      udp_query(port, "example.com", :a, 1)
      refute_receive {:event, _}, 100
      refute_receive {:resolved, _}, 50
    end
  end

  describe "catalog names" do
    test "no snapshot means fail-closed: locked and enforcing every tool", %{port: port} do
      reply = udp_query(port, "relay-1.net.anydesk.com", :a, 55)
      assert rcode(reply) == 3
      assert id(reply) == 55
      assert_receive {:event, %{type: :blocked, match: "anydesk", qtype: :a, client: @localhost}}
    end

    test "locked + enforce: nxdomain, :blocked event and a shadow lookup", %{port: port} do
      put(locked?: true, mode: :enforce)
      reply = udp_query(port, "relay-1.net.anydesk.com", :a, 1234)

      assert rcode(reply) == 3
      assert id(reply) == 1234
      assert ra?(reply)
      assert [{~c"relay-1.net.anydesk.com", :a}] = questions(reply)
      assert answers(reply) == []

      assert_receive {:event,
                      %{
                        type: :blocked,
                        qname: "relay-1.net.anydesk.com",
                        match: "anydesk",
                        channel: :control
                      } = ev}

      assert %DateTime{} = ev.at

      # the shadow lookup asks for both families
      assert_receive {:resolved, [{{10, 0, 0, 1}, 60, "anydesk"}]}
      assert_receive {:resolved, [{{0xFD00, 0, 0, 0, 0, 0, 0, 1}, 60, "anydesk"}]}
    end

    test "locked + monitor forwards and emits :would_block", %{port: port} do
      put(locked?: true, mode: :monitor)
      reply = udp_query(port, "relay-1.net.anydesk.com", :a, 3)

      assert_receive {:upstream_sent, sent}
      assert reply == sent
      assert_receive {:event, %{type: :would_block, match: "anydesk", channel: :control}}
      assert_receive {:resolved, entries}
      assert {{10, 0, 0, 1}, 60, "anydesk"} in entries
    end

    test "events carry the matched domain's channel", %{port: port} do
      put(locked?: true, mode: :monitor)

      for {name, tool, channel} <- [
            {"sis.n-able.com", "n_central", :management},
            {"app.ninjarmm.com", "ninjaone", :both}
          ] do
        udp_query(port, name, :a, 4)
        assert_receive {:event, %{type: :would_block, match: ^tool, channel: ^channel}}
      end
    end

    test "open forwards, records ips and emits nothing", %{port: port} do
      put(locked?: false, mode: :enforce)
      reply = udp_query(port, "instance-x.screenconnect.com", :a, 3)

      assert {:a, {10, 0, 0, 2}} in answers(reply)
      assert_receive {:resolved, [{{10, 0, 0, 2}, 30, "screenconnect"}]}
      refute_receive {:event, _}, 100
    end

    test "case and trailing-dot variants are blocked", %{port: port} do
      put(locked?: true, mode: :enforce)

      for name <- [
            "RELAY-1.Net.AnyDesk.COM",
            "relay-1.net.anydesk.com.",
            "Instance-X.ScreenConnect.com."
          ] do
        reply = udp_query(port, name, :a, 8)
        assert rcode(reply) == 3, name
        assert_receive {:event, %{type: :blocked}}
      end
    end

    test "the echoed question keeps the client's 0x20 casing", %{port: port} do
      put(locked?: true, mode: :enforce)
      reply = udp_query(port, "ReLaY-1.NeT.AnYdEsK.CoM", :a, 8)
      assert [{~c"ReLaY-1.NeT.AnYdEsK.CoM", :a}] = questions(reply)
    end

    test "other qtypes of a catalog name are blocked too", %{port: port} do
      put(locked?: true, mode: :enforce)
      reply = udp_query(port, "relay-1.net.anydesk.com", :txt, 8)
      assert rcode(reply) == 3
      assert_receive {:event, %{type: :blocked, qtype: :txt}}
    end

    test "tools outside the snapshot's tool_ids pass", %{port: port} do
      put(locked?: true, mode: :enforce, tool_ids: ["teamviewer"])
      reply = udp_query(port, "relay-1.net.anydesk.com", :a, 8)
      assert rcode(reply) == 0
      refute_receive {:event, _}, 100
    end

    test "tcp clients get nxdomain too", %{port: port} do
      put(locked?: true, mode: :enforce)
      reply = tcp_query(port, "relay-1.net.anydesk.com", :a, 77)
      assert rcode(reply) == 3
      assert id(reply) == 77
    end
  end

  describe "site hostnames" do
    test "locked + enforce blocks an exact site host", %{port: port} do
      put(locked?: true, mode: :enforce, site_hostnames: ["RMM.Client.Example."])
      reply = udp_query(port, "rmm.client.example", :a, 9)

      assert rcode(reply) == 3

      assert_receive {:event,
                      %{type: :blocked, match: {:site_host, "rmm.client.example"}, channel: nil}}

      assert_receive {:resolved, [{{10, 0, 0, 3}, 120, {:site_host, "rmm.client.example"}}]}
    end

    test "subdomains of a site host are not matched", %{port: port} do
      put(locked?: true, mode: :enforce, site_hostnames: ["client.example"])
      reply = udp_query(port, "rmm.client.example", :a, 9)
      assert rcode(reply) == 0
    end

    test "open records site host ips", %{port: port} do
      put(locked?: false, mode: :enforce, site_hostnames: ["rmm.client.example"])
      reply = udp_query(port, "rmm.client.example", :a, 9)
      assert {:a, {10, 0, 0, 3}} in answers(reply)
      assert_receive {:resolved, [{{10, 0, 0, 3}, 120, {:site_host, "rmm.client.example"}}]}
    end
  end

  describe "cname into a catalog name" do
    test "locked + enforce returns nxdomain for a vanity cname", %{port: port} do
      put(locked?: true, mode: :enforce)
      reply = udp_query(port, "support.msp.example", :a, 21)

      assert rcode(reply) == 3
      assert id(reply) == 21

      assert_receive {:event,
                      %{
                        type: :blocked,
                        qname: "support.msp.example",
                        match: {:cname, "instance-x.screenconnect.com", "screenconnect"},
                        channel: :control
                      }}

      assert_receive {:resolved, [{{10, 0, 0, 2}, 30, "screenconnect"}]}
    end

    test "locked + monitor returns the upstream answer and :would_block", %{port: port} do
      put(locked?: true, mode: :monitor)
      reply = udp_query(port, "support.msp.example", :a, 21)

      assert_receive {:upstream_sent, sent}
      assert reply == sent
      assert_receive {:event, %{type: :would_block, match: {:cname, _, "screenconnect"}}}
      assert_receive {:resolved, [{{10, 0, 0, 2}, 30, "screenconnect"}]}
    end

    test "open returns the upstream answer and still records ips", %{port: port} do
      put(locked?: false, mode: :enforce)
      reply = udp_query(port, "support.msp.example", :a, 21)

      assert_receive {:upstream_sent, sent}
      assert reply == sent
      assert_receive {:resolved, [{{10, 0, 0, 2}, 30, "screenconnect"}]}
      refute_receive {:event, _}, 100
    end

    test "a cname into a site host is caught", %{port: port} do
      put(locked?: true, mode: :enforce, site_hostnames: ["rmm.client.example"])
      reply = udp_query(port, "alias.client.example", :a, 21)

      assert rcode(reply) == 3

      assert_receive {:event,
                      %{match: {:cname, "rmm.client.example", {:site_host, "rmm.client.example"}}}}
    end
  end

  describe "doh hostnames and canaries" do
    test "always nxdomain, whatever the lock state", %{port: port} do
      for open <- [true, false], mode <- [:enforce, :monitor] do
        put(locked?: not open, mode: mode)

        for name <- ["dns.google", "Cloudflare-DNS.com.", "abc123.dns.nextdns.io"] do
          reply = udp_query(port, name, :a, 5)
          assert rcode(reply) == 3, name
          assert_receive {:event, %{type: :doh_blocked, match: {:doh, _}, channel: nil}}
        end

        for name <- ["use-application-dns.net", "mask.icloud.com", "mask-h2.icloud.com"] do
          reply = udp_query(port, name, :a, 5)
          assert rcode(reply) == 3, name
          assert_receive {:event, %{type: :doh_blocked, match: {:canary, ^name}}}
        end
      end

      refute_receive {:upstream_sent, _}, 50
    end
  end

  describe "upstream failure" do
    test "a silent upstream gives servfail after the timeout" do
      silent = start_upstream(self(), :silent)
      dns = start_dns([silent], timeout_ms: 100, name: :silent_dns)
      reply = udp_query(Gateway.DNS.port(dns), "example.com", :a, 66)
      assert rcode(reply) == 2
      assert id(reply) == 66
    end

    test "the next upstream is tried after a silent one", %{upstream: good} do
      silent = start_upstream(self(), :silent)
      dns = start_dns([silent, good], timeout_ms: 100, name: :fallback_dns)
      reply = udp_query(Gateway.DNS.port(dns), "example.com", :a, 67)
      assert {:a, {93, 184, 216, 34}} in answers(reply)
    end
  end

  describe "malformed input" do
    test "garbage packets never crash the listener", %{port: port, dns: dns} do
      server = server_pid(dns)
      {:ok, sock} = :gen_udp.open(0, [:binary, active: false])

      for _ <- 1..400 do
        len = :rand.uniform(600) - 1
        :gen_udp.send(sock, @localhost, port, :crypto.strong_rand_bytes(len))
      end

      # garbage behind a valid query header (qr = 0, one question)
      for _ <- 1..200 do
        tail = :crypto.strong_rand_bytes(:rand.uniform(80))
        :gen_udp.send(sock, @localhost, port, <<1::16, 0x0100::16, 1::16, 0::48, tail::binary>>)
      end

      # truncated headers
      for len <- 0..11, do: :gen_udp.send(sock, @localhost, port, :binary.copy(<<0>>, len))

      :gen_udp.close(sock)

      assert Process.alive?(server)
      assert server_pid(dns) == server

      # the burst can overflow the socket's receive buffer, which drops packets
      # like any udp server would; a real client retries, and so does this one
      reply = udp_query_retry(port, "example.com", :a, 31337, 5)
      assert {:a, {93, 184, 216, 34}} in answers(reply)
    end

    test "an undecodable query gets formerr with the same id", %{port: port} do
      {:ok, sock} = :gen_udp.open(0, [:binary, active: false])
      # header says one question, but the label runs past the end
      :gen_udp.send(sock, @localhost, port, <<0xBEEF::16, 0x0100::16, 1::16, 0::48, 40, "abc">>)
      {:ok, {_, _, reply}} = :gen_udp.recv(sock, 0, 2000)
      :gen_udp.close(sock)
      assert <<0xBEEF::16, 1::1, _::11, 1::4, _::binary>> = reply
    end

    test "a standard query with two questions gets formerr", %{port: port} do
      packet =
        :inet_dns.encode(
          dns_rec(
            header: dns_header(id: 12, opcode: :query, rd: true),
            qdlist: [
              dns_query(domain: ~c"example.com", type: :a, class: :in),
              dns_query(domain: ~c"relay-1.net.anydesk.com", type: :a, class: :in)
            ]
          )
        )

      reply = raw_udp(port, packet)
      assert rcode(reply) == 1
      refute_receive {:upstream_sent, _}, 50
    end

    test "other opcodes get notimp and are never forwarded", %{port: port} do
      packet =
        :inet_dns.encode(
          dns_rec(
            header: dns_header(id: 13, opcode: :notify, rd: true),
            qdlist: [dns_query(domain: ~c"relay-1.net.anydesk.com", type: :soa, class: :in)]
          )
        )

      reply = raw_udp(port, packet)
      assert <<13::16, _::binary>> = reply
      assert rcode(reply) == 4
      refute_receive {:upstream_sent, _}, 50
    end

    test "idle tcp connections are closed", %{upstream: up} do
      dns = start_dns([up], name: :idle_dns, tcp_idle_ms: 100)
      port = Gateway.DNS.port(dns)
      {:ok, sock} = :gen_tcp.connect(@localhost, port, [:binary, packet: 2, active: false])
      assert {:error, :closed} = :gen_tcp.recv(sock, 0, 2000)
    end

    test "several queries share one tcp connection", %{port: port} do
      {:ok, sock} = :gen_tcp.connect(@localhost, port, [:binary, packet: 2, active: false])

      for id <- 1..3 do
        :ok = :gen_tcp.send(sock, query_packet("example.com", :a, id))
        assert {:ok, <<^id::16, _::binary>>} = :gen_tcp.recv(sock, 0, 2000)
      end

      :gen_tcp.close(sock)
    end

    test "garbage over tcp does not crash the listener", %{port: port, dns: dns} do
      server = server_pid(dns)
      {:ok, sock} = :gen_tcp.connect(@localhost, port, [:binary, packet: 2, active: false])
      for _ <- 1..50, do: :gen_tcp.send(sock, :crypto.strong_rand_bytes(:rand.uniform(300)))
      :gen_tcp.close(sock)

      assert Process.alive?(server)
      reply = tcp_query(port, "example.com", :a, 8)
      assert {:a, {93, 184, 216, 34}} in answers(reply)
    end
  end

  describe "dual-stack listener" do
    test "bound to ::, it answers ipv4 and ipv6 clients and reports plain ipv4 peers",
         %{upstream: up} do
      dns = start_dns([up], ip: {0, 0, 0, 0, 0, 0, 0, 0}, name: :dual_stack)
      port = Gateway.DNS.port(dns)
      put(locked?: true, mode: :enforce)

      assert rcode(udp_query(port, "relay-1.net.anydesk.com", :a, 1)) == 3
      assert_receive {:event, %{type: :blocked, client: @localhost}}

      assert rcode(tcp_query(port, "relay-1.net.anydesk.com", :a, 2)) == 3
      assert_receive {:event, %{type: :blocked, client: @localhost}}

      {:ok, sock} = :gen_udp.open(0, [:binary, :inet6, active: false])

      :ok =
        :gen_udp.send(sock, {0, 0, 0, 0, 0, 0, 0, 1}, port, query_packet("example.com", :a, 3))

      assert {:ok, {_, _, reply}} = :gen_udp.recv(sock, 0, 3000)
      :gen_udp.close(sock)
      assert id(reply) == 3
    end

    test "client_ip/1 unmaps ::ffff:a.b.c.d and leaves other addresses alone" do
      alias Gateway.DNS.Server
      assert Server.client_ip({0, 0, 0, 0, 0, 0xFFFF, 0x0A0A, 0x0002}) == {10, 10, 0, 2}
      assert Server.client_ip({10, 10, 0, 2}) == {10, 10, 0, 2}
      assert Server.client_ip({0xFD00, 0, 0, 0, 0, 0, 0, 2}) == {0xFD00, 0, 0, 0, 0, 0, 0, 2}
    end
  end

  describe "callbacks" do
    @tag :capture_log
    test "a raising on_event or on_resolved does not break the query", %{upstream: up} do
      dns =
        start_dns([up],
          name: :raising_dns,
          on_event: fn _ -> raise "boom" end,
          on_resolved: fn _ -> throw(:nope) end
        )

      put(locked?: true, mode: :monitor)
      reply = udp_query(Gateway.DNS.port(dns), "relay-1.net.anydesk.com", :a, 4)
      assert {:a, {10, 0, 0, 1}} in answers(reply)
    end
  end

  test "snapshot default is fail-closed" do
    Snapshot.clear()
    snap = Snapshot.get()
    assert snap.locked?
    assert snap.mode == :enforce
    assert snap.tool_ids == Breakline.Catalog.ids()
    assert snap.site_hostnames == []
  end

  ## helpers

  defp put(opts) do
    Snapshot.put(%Snapshot{
      locked?: Keyword.fetch!(opts, :locked?),
      mode: Keyword.fetch!(opts, :mode),
      tool_ids: Keyword.get(opts, :tool_ids, Breakline.Catalog.ids()),
      site_hostnames: Keyword.get(opts, :site_hostnames, [])
    })
  end

  defp start_dns(upstreams, opts \\ []) do
    test = self()

    opts =
      Keyword.merge(
        [
          ip: @localhost,
          port: 0,
          upstreams: upstreams,
          timeout_ms: 500,
          on_resolved: fn entries -> send(test, {:resolved, entries}) end,
          on_event: fn event -> send(test, {:event, event}) end
        ],
        opts
      )

    start_supervised!({Gateway.DNS, opts}, id: Keyword.get(opts, :name, Gateway.DNS))
  end

  defp server_pid(dns) do
    {_, pid, _, _} =
      dns |> Supervisor.which_children() |> Enum.find(&(elem(&1, 0) == Gateway.DNS.Server))

    pid
  end

  # a fake upstream on udp and tcp at the same port. :answer serves @answers,
  # :silent reads and never replies.
  defp start_upstream(test, behaviour) do
    parent = self()

    pid =
      spawn_link(fn ->
        {udp, lsock, port} = open_udp_and_tcp(20)
        spawn_link(fn -> upstream_accept(lsock, test) end)
        send(parent, {:upstream_port, self(), port})
        upstream_loop(udp, test, behaviour)
      end)

    receive do
      {:upstream_port, ^pid, port} -> {@localhost, port}
    end
  end

  # the free udp port the kernel picks can already be taken for tcp on a busy host,
  # so retry with a fresh port instead of failing the test
  defp open_udp_and_tcp(attempts) when attempts > 0 do
    {:ok, udp} = :gen_udp.open(0, [:binary, ip: @localhost, active: true])
    {:ok, port} = :inet.port(udp)

    tcp_opts = [:binary, ip: @localhost, packet: 2, active: false, reuseaddr: true]

    case :gen_tcp.listen(port, tcp_opts) do
      {:ok, lsock} ->
        {udp, lsock, port}

      {:error, :eaddrinuse} ->
        :gen_udp.close(udp)
        open_udp_and_tcp(attempts - 1)
    end
  end

  defp upstream_loop(udp, test, behaviour) do
    receive do
      {:udp, ^udp, ip, port, query} ->
        with :answer <- behaviour, {:ok, reply} <- upstream_reply(query, :udp) do
          send(test, {:upstream_sent, reply})
          :gen_udp.send(udp, ip, port, reply)
        end

        upstream_loop(udp, test, behaviour)
    end
  end

  defp upstream_accept(lsock, test) do
    {:ok, sock} = :gen_tcp.accept(lsock)

    with {:ok, query} <- :gen_tcp.recv(sock, 0, 2000),
         {:ok, reply} <- upstream_reply(query, :tcp) do
      send(test, {:upstream_tcp, query})
      :gen_tcp.send(sock, reply)
    end

    :gen_tcp.close(sock)
    upstream_accept(lsock, test)
  end

  # garbage that the gateway forwards as-is must not crash the fake upstream
  defp upstream_reply(query, transport) do
    {:ok, build_reply(query, transport)}
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp build_reply(query, transport) do
    {:ok, msg} = :inet_dns.decode(query)
    [q] = dns_rec(msg, :qdlist)
    name = q |> dns_query(:domain) |> List.to_string() |> String.downcase()
    qtype = dns_query(q, :type)
    header = dns_rec(msg, :header)

    records =
      @answers
      |> Map.get(name, [])
      |> Enum.filter(fn {type, _, _, _} -> type == :cname or type == qtype end)

    {tc, records} =
      if name == "big.example" and transport == :udp, do: {true, []}, else: {false, records}

    anlist =
      for {type, owner, data, ttl} <- records do
        data = if type == :cname, do: String.to_charlist(data), else: data
        dns_rr(domain: String.to_charlist(owner), type: type, class: :in, ttl: ttl, data: data)
      end

    rcode = if Map.has_key?(@answers, name), do: 0, else: 3

    :inet_dns.encode(
      dns_rec(msg,
        header: dns_header(header, qr: true, ra: true, tc: tc, rcode: rcode),
        anlist: anlist
      )
    )
  end

  defp query_packet(name, type, id) do
    :inet_dns.encode(
      dns_rec(
        header: dns_header(id: id, opcode: :query, rd: true),
        qdlist: [dns_query(domain: String.to_charlist(name), type: type, class: :in)]
      )
    )
  end

  defp udp_query(port, name, type, id), do: raw_udp(port, query_packet(name, type, id))

  defp raw_udp(port, packet) do
    {:ok, sock} = :gen_udp.open(0, [:binary, active: false])
    :ok = :gen_udp.send(sock, @localhost, port, packet)
    {:ok, {_, _, reply}} = :gen_udp.recv(sock, 0, 3000)
    :gen_udp.close(sock)
    reply
  end

  defp udp_query_retry(port, name, type, id, attempts) do
    {:ok, sock} = :gen_udp.open(0, [:binary, active: false])

    reply =
      Enum.find_value(1..attempts, fn _ ->
        :ok = :gen_udp.send(sock, @localhost, port, query_packet(name, type, id))

        case :gen_udp.recv(sock, 0, 1000) do
          {:ok, {_, _, <<^id::16, _::binary>> = reply}} -> reply
          _ -> nil
        end
      end)

    :gen_udp.close(sock)
    reply || flunk("no reply after #{attempts} attempts")
  end

  defp tcp_query(port, name, type, id) do
    {:ok, sock} = :gen_tcp.connect(@localhost, port, [:binary, packet: 2, active: false])
    :ok = :gen_tcp.send(sock, query_packet(name, type, id))
    {:ok, reply} = :gen_tcp.recv(sock, 0, 3000)
    :gen_tcp.close(sock)
    reply
  end

  defp id(<<id::16, _::binary>>), do: id
  defp rcode(<<_::28, rcode::4, _::binary>>), do: rcode
  defp ra?(<<_::24, ra::1, _::7, _::binary>>), do: ra == 1
  defp truncated?(<<_::22, tc::1, _::9, _::binary>>), do: tc == 1

  defp questions(reply) do
    {:ok, msg} = :inet_dns.decode(reply)
    for q <- dns_rec(msg, :qdlist), do: {dns_query(q, :domain), dns_query(q, :type)}
  end

  defp answers(reply) do
    {:ok, msg} = :inet_dns.decode(reply)
    for rr <- dns_rec(msg, :anlist), do: {dns_rr(rr, :type), dns_rr(rr, :data)}
  end
end
