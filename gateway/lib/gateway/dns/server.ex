defmodule Gateway.DNS.Server do
  @moduledoc """
  Owns the UDP socket and the TCP listen socket, both bound to the same ip and
  port, and hands every query to a task under the query `Task.Supervisor`.

  The listener itself never decodes a packet, so malformed input cannot crash
  it. When the task supervisor is at its limit, new UDP packets are dropped and
  new TCP connections are closed, and clients retry. The TCP acceptor is a
  linked process; each accepted connection runs in its own task, reads
  length-prefixed messages one at a time, and is closed after an idle timeout.
  """

  use GenServer

  import Bitwise

  require Logger

  alias Gateway.DNS.{Packet, Resolver}

  @udp_active 100

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Returns the port the listener is bound to."
  @spec port(GenServer.server()) :: :inet.port_number()
  def port(server), do: GenServer.call(server, :port)

  @impl true
  def init(opts) do
    ip = Keyword.fetch!(opts, :ip)
    family = if tuple_size(ip) == 8, do: :inet6, else: :inet

    udp_opts = [:binary, family, ip: ip, active: @udp_active, reuseaddr: true]

    with {:ok, udp, port, lsock} <- open_sockets(Keyword.fetch!(opts, :port), udp_opts, opts, 20) do
      ctx = %{
        upstreams: Keyword.fetch!(opts, :upstreams),
        timeout_ms: Keyword.fetch!(opts, :timeout_ms),
        on_resolved: Keyword.fetch!(opts, :on_resolved),
        on_event: Keyword.fetch!(opts, :on_event),
        task_sup: nil
      }

      state = %{
        udp: udp,
        tcp: lsock,
        port: port,
        idle: Keyword.fetch!(opts, :tcp_idle_ms),
        ctx: ctx
      }

      {:ok, state, {:continue, {:find_task_sup, Keyword.fetch!(opts, :sup)}}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  # runs after the parent supervisor has finished starting us, so asking it for
  # our sibling cannot deadlock. packets that arrive meanwhile wait in the mailbox.
  @impl true
  def handle_continue({:find_task_sup, sup}, state) do
    {_, task_sup, _, _} =
      sup
      |> Supervisor.which_children()
      |> Enum.find(fn {id, _, _, _} -> id == Task.Supervisor end)

    ctx = %{state.ctx | task_sup: task_sup}

    if state.tcp do
      lsock = state.tcp
      idle = state.idle
      spawn_link(fn -> accept_loop(lsock, ctx, idle) end)
    end

    {:noreply, %{state | ctx: ctx}}
  end

  # with port 0 the kernel picks a free udp port, but that number can already be
  # taken for tcp, so pick again rather than failing. a fixed port fails at once.
  defp open_sockets(requested, udp_opts, opts, attempts) do
    ip = Keyword.fetch!(opts, :ip)
    family = if tuple_size(ip) == 8, do: :inet6, else: :inet

    with {:ok, udp} <- :gen_udp.open(requested, udp_opts),
         {:ok, port} <- :inet.port(udp) do
      case listen_tcp(opts[:tcp], ip, family, port) do
        {:ok, lsock} ->
          {:ok, udp, port, lsock}

        {:error, :eaddrinuse} when requested == 0 and attempts > 1 ->
          :gen_udp.close(udp)
          open_sockets(requested, udp_opts, opts, attempts - 1)

        {:error, reason} ->
          :gen_udp.close(udp)
          {:error, reason}
      end
    end
  end

  defp listen_tcp(false, _ip, _family, _port), do: {:ok, nil}

  defp listen_tcp(_enabled, ip, family, port) do
    opts = [:binary, family, ip: ip, packet: 2, active: false, reuseaddr: true, backlog: 128]
    :gen_tcp.listen(port, opts)
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  @impl true
  def handle_info({:udp, sock, ip, port, packet}, %{udp: sock} = state) do
    ctx = Map.merge(state.ctx, %{client: client_ip(ip), transport: :udp})

    _ =
      Task.Supervisor.start_child(state.ctx.task_sup, fn ->
        case run(packet, ctx) do
          {:reply, reply} -> :gen_udp.send(sock, ip, port, reply)
          :drop -> :ok
        end
      end)

    {:noreply, state}
  end

  def handle_info({:udp_passive, sock}, %{udp: sock} = state) do
    :ok = :inet.setopts(sock, active: @udp_active)
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug("dns server ignored #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.tcp, do: :gen_tcp.close(state.tcp)
    :gen_udp.close(state.udp)
  end

  @doc false
  # a socket bound to :: takes ipv4 as well, and those peers show up as ::ffff:a.b.c.d.
  # events carry the plain ipv4 address, replies still go to the mapped one
  @spec client_ip(:inet.ip_address()) :: :inet.ip_address()
  def client_ip({0, 0, 0, 0, 0, 0xFFFF, ab, cd}),
    do: {ab >>> 8, ab &&& 0xFF, cd >>> 8, cd &&& 0xFF}

  def client_ip(ip), do: ip

  @doc false
  # the resolver should never raise, but a bad packet must cost one task at most
  @spec run(binary(), Resolver.ctx()) :: {:reply, binary()} | :drop
  def run(packet, ctx) do
    Resolver.handle(packet, ctx)
  rescue
    e ->
      Logger.warning("dns query failed: " <> Exception.message(e))
      if Packet.query?(packet), do: {:reply, Packet.servfail(packet)}, else: :drop
  catch
    _, _ -> if Packet.query?(packet), do: {:reply, Packet.servfail(packet)}, else: :drop
  end

  defp accept_loop(lsock, ctx, idle) do
    case :gen_tcp.accept(lsock) do
      {:ok, sock} ->
        start_conn(sock, ctx, idle)
        accept_loop(lsock, ctx, idle)

      {:error, :closed} ->
        exit(:normal)

      {:error, reason} ->
        Logger.warning("dns tcp accept failed: #{inspect(reason)}")
        accept_loop(lsock, ctx, idle)
    end
  end

  defp start_conn(sock, ctx, idle) do
    client =
      case :inet.peername(sock) do
        {:ok, {ip, _port}} -> client_ip(ip)
        _ -> nil
      end

    ctx = Map.merge(ctx, %{client: client, transport: :tcp})

    task =
      Task.Supervisor.start_child(ctx.task_sup, fn ->
        receive do
          :go -> conn_loop(sock, ctx, idle)
        after
          idle -> :gen_tcp.close(sock)
        end
      end)

    with {:ok, pid} <- task,
         :ok <- :gen_tcp.controlling_process(sock, pid) do
      send(pid, :go)
    else
      _ -> :gen_tcp.close(sock)
    end
  end

  defp conn_loop(sock, ctx, idle) do
    case :gen_tcp.recv(sock, 0, idle) do
      {:ok, packet} ->
        case run(packet, ctx) do
          {:reply, reply} -> :gen_tcp.send(sock, reply)
          :drop -> :ok
        end

        conn_loop(sock, ctx, idle)

      {:error, _} ->
        :gen_tcp.close(sock)
    end
  end
end
