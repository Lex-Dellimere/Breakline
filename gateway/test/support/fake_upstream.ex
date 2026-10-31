defmodule Gateway.FakeUpstream do
  @moduledoc false
  # a canned dns upstream on udp and tcp at the same localhost port. answers is a map
  # of lowercase qname => [{type, owner, data, ttl}]; unknown names get nxdomain.

  require Record

  @hrl "kernel/src/inet_dns.hrl"
  Record.defrecordp(:dns_rec, Record.extract(:dns_rec, from_lib: @hrl))
  Record.defrecordp(:dns_header, Record.extract(:dns_header, from_lib: @hrl))
  Record.defrecordp(:dns_query, Record.extract(:dns_query, from_lib: @hrl))
  Record.defrecordp(:dns_rr, Record.extract(:dns_rr, from_lib: @hrl))

  @localhost {127, 0, 0, 1}

  def start(answers) do
    parent = self()

    pid =
      spawn_link(fn ->
        {udp, lsock, port} = open_udp_and_tcp(20)
        spawn_link(fn -> accept(lsock, answers) end)
        send(parent, {:upstream_port, self(), port})
        loop(udp, answers)
      end)

    receive do
      {:upstream_port, ^pid, port} -> {@localhost, port}
    end
  end

  # the free udp port the kernel picks can already be taken for tcp, so retry
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

  defp loop(udp, answers) do
    receive do
      {:udp, ^udp, ip, port, query} ->
        with {:ok, reply} <- reply(query, answers), do: :gen_udp.send(udp, ip, port, reply)
        loop(udp, answers)
    end
  end

  defp accept(lsock, answers) do
    {:ok, sock} = :gen_tcp.accept(lsock)

    with {:ok, query} <- :gen_tcp.recv(sock, 0, 2000),
         {:ok, reply} <- reply(query, answers) do
      :gen_tcp.send(sock, reply)
    end

    :gen_tcp.close(sock)
    accept(lsock, answers)
  end

  defp reply(query, answers) do
    {:ok, msg} = :inet_dns.decode(query)
    [q] = dns_rec(msg, :qdlist)
    name = q |> dns_query(:domain) |> List.to_string() |> String.downcase()
    qtype = dns_query(q, :type)

    anlist =
      for {type, owner, data, ttl} <- Map.get(answers, name, []),
          type == :cname or type == qtype do
        data = if type == :cname, do: String.to_charlist(data), else: data
        dns_rr(domain: String.to_charlist(owner), type: type, class: :in, ttl: ttl, data: data)
      end

    rcode = if Map.has_key?(answers, name), do: 0, else: 3
    header = dns_header(dns_rec(msg, :header), qr: true, ra: true, rcode: rcode)
    {:ok, :inet_dns.encode(dns_rec(msg, header: header, anlist: anlist))}
  rescue
    _ -> :error
  end

  # client side

  def query(port, name, type \\ :a, id \\ 1) do
    packet =
      :inet_dns.encode(
        dns_rec(
          header: dns_header(id: id, opcode: :query, rd: true),
          qdlist: [dns_query(domain: String.to_charlist(name), type: type, class: :in)]
        )
      )

    {:ok, sock} = :gen_udp.open(0, [:binary, active: false])
    :ok = :gen_udp.send(sock, @localhost, port, packet)
    {:ok, {_, _, reply}} = :gen_udp.recv(sock, 0, 3000)
    :gen_udp.close(sock)
    reply
  end

  def rcode(<<_::28, rcode::4, _::binary>>), do: rcode

  def answers(reply) do
    {:ok, msg} = :inet_dns.decode(reply)
    for rr <- dns_rec(msg, :anlist), do: {dns_rr(rr, :type), dns_rr(rr, :data)}
  end
end
