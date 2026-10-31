defmodule Gateway.DNS.Upstream do
  @moduledoc """
  Forwards a raw query to the upstream resolvers.

  Each upstream is tried in order over UDP. A reply only counts if it comes
  from that upstream's address and port and carries the query's id. If the
  reply has the TC bit set, the same upstream is asked again over TCP so the
  gateway sees the full answer, including any CNAME chain. The query bytes are
  sent unchanged, so the client's id, flags and EDNS options reach the
  upstream as the client sent them.
  """

  alias Gateway.DNS.Packet

  @type upstream :: {:inet.ip_address(), :inet.port_number()}

  @typedoc """
  `full` is the complete answer. `truncated` is the UDP reply with TC set when
  `full` came over TCP after it, otherwise nil. A UDP client whose buffer is
  too small for `full` gets `truncated` and retries over TCP itself.
  """
  @type result :: %{full: binary(), truncated: binary() | nil}

  @doc """
  Sends `query` to each upstream in turn until one answers. Returns `:error` if
  none did within `timeout_ms` each. If every TCP retry failed, the last
  truncated UDP reply is returned as the full answer, since it is still a valid
  reply.
  """
  @spec query(binary(), [upstream()], pos_integer()) :: {:ok, result()} | :error
  def query(query, upstreams, timeout_ms) do
    id = Packet.id(query)

    Enum.reduce_while(upstreams, :error, fn upstream, fallback ->
      case udp(query, id, upstream, timeout_ms) do
        {:ok, reply} ->
          if Packet.truncated?(reply) do
            case tcp(query, id, upstream, timeout_ms) do
              {:ok, full} -> {:halt, {:ok, %{full: full, truncated: reply}}}
              :error -> {:cont, {:ok, %{full: reply, truncated: nil}}}
            end
          else
            {:halt, {:ok, %{full: reply, truncated: nil}}}
          end

        :error ->
          {:cont, fallback}
      end
    end)
  end

  @doc "Sends one query over UDP to one upstream and waits for the matching reply."
  @spec udp(binary(), non_neg_integer(), upstream(), pos_integer()) :: {:ok, binary()} | :error
  def udp(query, id, {ip, port}, timeout_ms) do
    case :gen_udp.open(0, [:binary, family(ip), active: false]) do
      {:ok, sock} ->
        try do
          with :ok <- :gen_udp.send(sock, ip, port, query) do
            deadline = System.monotonic_time(:millisecond) + timeout_ms
            await_udp(sock, id, ip, port, deadline)
          else
            _ -> :error
          end
        after
          :gen_udp.close(sock)
        end

      {:error, _} ->
        :error
    end
  end

  # replies from the wrong source or with the wrong id are ignored until the deadline
  defp await_udp(sock, id, ip, port, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      :error
    else
      case :gen_udp.recv(sock, 0, remaining) do
        {:ok, {^ip, ^port, <<^id::16, _::binary>> = reply}} -> {:ok, reply}
        {:ok, _other} -> await_udp(sock, id, ip, port, deadline)
        {:error, _} -> :error
      end
    end
  end

  @doc "Sends one query over TCP (2-byte length framing) to one upstream."
  @spec tcp(binary(), non_neg_integer(), upstream(), pos_integer()) :: {:ok, binary()} | :error
  def tcp(query, id, {ip, port}, timeout_ms) do
    opts = [:binary, family(ip), packet: 2, active: false, send_timeout: timeout_ms]

    case :gen_tcp.connect(ip, port, opts, timeout_ms) do
      {:ok, sock} ->
        try do
          with :ok <- :gen_tcp.send(sock, query),
               {:ok, <<^id::16, _::binary>> = reply} <- :gen_tcp.recv(sock, 0, timeout_ms) do
            {:ok, reply}
          else
            _ -> :error
          end
        after
          :gen_tcp.close(sock)
        end

      {:error, _} ->
        :error
    end
  end

  defp family(ip) when tuple_size(ip) == 8, do: :inet6
  defp family(_ip), do: :inet
end
