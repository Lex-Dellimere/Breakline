defmodule Gateway.Firewall do
  @moduledoc """
  The gateway firewall: a behaviour for firewall implementations and a facade over
  `Gateway.Firewall.Server`, which owns the implementation state.

  The firewall holds two kinds of state:

    * the static ruleset, rebuilt from a `Gateway.Firewall.Desired` on every
      `apply_desired/1`: the DNS redirect, the DoT and DoH drops, and, while locked,
      the drops for RMM addresses, blocked CIDRs and RMM-only ports;
    * the dynamic resolved-address sets, filled by `add_resolved/1` as the gateway
      resolver answers queries for catalog domains. Each element expires on its own
      after its clamped TTL, and an apply never removes them, so a policy change or a
      lock never forgets addresses resolved while the channel was open.

  Implementations are `Gateway.Firewall.NftImpl` (nftables through `nft -j`) and
  `Gateway.Firewall.FakeImpl` (in memory, for dev and tests). Their state is passed
  explicitly so each callback can be tested without a process.
  """

  alias Gateway.Firewall.{Desired, Server}

  @typedoc "One resolved RMM address: the ip tuple, the DNS TTL in seconds and the tool id."
  @type resolved :: {:inet.ip_address(), non_neg_integer(), String.t()}

  @typedoc "Implementation state, opaque to callers."
  @type state :: term()

  @default_ttl_floor 3_600
  @default_ttl_cap 86_400

  @doc "Initialises the implementation. Must not touch the firewall."
  @callback init(opts :: keyword()) :: {:ok, state()}

  @doc """
  Replaces the static ruleset with the one described by the desired state, atomically.
  Applying the same desired state twice has the same effect as applying it once. The
  dynamic resolved-address sets must be left untouched.
  """
  @callback apply_desired(Desired.t(), state()) :: {:ok, state()} | {:error, term(), state()}

  @doc """
  Adds resolved RMM addresses to the dynamic sets, each with a timeout of its TTL
  clamped to the configured floor and cap (see `clamp_ttl/3`).
  """
  @callback add_resolved([resolved()], state()) :: {:ok, state()} | {:error, term(), state()}

  @doc "Returns a map describing the current state, for status pages and tests."
  @callback snapshot(state()) :: map()

  @doc """
  Applies a desired state through the running server. Returns `{:error, :not_running}`
  when the server is not started.
  """
  @spec apply_desired(Desired.t(), GenServer.server()) :: :ok | {:error, term()}
  def apply_desired(%Desired{} = desired, server \\ Server) do
    GenServer.call(server, {:apply_desired, desired}, 30_000)
  catch
    :exit, {:noproc, _} -> {:error, :not_running}
  end

  @doc """
  Adds resolved RMM addresses without blocking the caller. This is a cast: it is a
  no-op when the server is not running, and failures are logged by the server.
  """
  @spec add_resolved([resolved()], GenServer.server()) :: :ok
  def add_resolved(resolved, server \\ Server) when is_list(resolved) do
    GenServer.cast(server, {:add_resolved, resolved})
  end

  @doc """
  Returns the server's snapshot: the last applied desired state, the last error and
  the implementation's own snapshot. Returns `{:error, :not_running}` when the server
  is not started.
  """
  @spec snapshot(GenServer.server()) :: map() | {:error, :not_running}
  def snapshot(server \\ Server) do
    GenServer.call(server, :snapshot)
  catch
    :exit, {:noproc, _} -> {:error, :not_running}
  end

  @doc """
  Clamps a DNS TTL to `[floor, cap]` seconds. The floor keeps short-TTL addresses
  blocked long after the client last resolved them; the cap stops the set growing
  without bound.

      iex> Gateway.Firewall.clamp_ttl(30)
      3600
      iex> Gateway.Firewall.clamp_ttl(1_000_000)
      86400
  """
  @spec clamp_ttl(integer(), pos_integer(), pos_integer()) :: pos_integer()
  def clamp_ttl(ttl, floor \\ @default_ttl_floor, cap \\ @default_ttl_cap) do
    ttl |> max(floor) |> min(cap)
  end

  @doc "Reads the ttl floor and cap from implementation opts, with the defaults."
  @spec ttl_bounds(keyword()) :: {pos_integer(), pos_integer()}
  def ttl_bounds(opts) do
    floor = Keyword.get(opts, :ttl_floor, @default_ttl_floor)
    cap = Keyword.get(opts, :ttl_cap, @default_ttl_cap)

    unless is_integer(floor) and is_integer(cap) and floor > 0 and cap >= floor do
      raise ArgumentError, "invalid ttl bounds #{inspect({floor, cap})}"
    end

    {floor, cap}
  end

  @doc """
  Keeps the valid entries of a resolved list (an ipv4 or ipv6 tuple, an integer ttl
  and a binary tool id) and returns `{valid, invalid}`.
  """
  @spec validate_resolved([term()]) :: {[resolved()], [term()]}
  def validate_resolved(list) do
    Enum.split_with(list, fn
      {ip, ttl, tool} when is_integer(ttl) and is_binary(tool) -> ip?(ip)
      _ -> false
    end)
  end

  defp ip?(ip) when is_tuple(ip) and tuple_size(ip) in [4, 8] do
    max = if tuple_size(ip) == 4, do: 255, else: 0xFFFF
    ip |> Tuple.to_list() |> Enum.all?(&(is_integer(&1) and &1 in 0..max))
  end

  defp ip?(_), do: false
end
