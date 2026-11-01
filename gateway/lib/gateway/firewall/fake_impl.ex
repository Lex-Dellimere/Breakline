defmodule Gateway.Firewall.FakeImpl do
  @moduledoc """
  An in-memory `Gateway.Firewall` implementation for dev and tests.

  It records the last applied `Gateway.Firewall.Desired` and the resolved RMM
  addresses with their expiry, the way the nftables sets would hold them. Expired
  addresses disappear from the snapshot. Adding an address again resets its expiry
  to the new clamped TTL, which is what the kernel does with `add element` on a
  timeout set (checked on Linux 6.12). Duplicates within one call keep the longest
  TTL, like `Gateway.Firewall.NftImpl.Ruleset.resolved/1`.

  Options:

    * `clock:` - a zero-arity function returning the current time in whole seconds
      (defaults to `System.monotonic_time(:second)`), so tests can move time
    * `ttl_floor:` and `ttl_cap:` - see `Gateway.Firewall.clamp_ttl/3`
    * `fail_apply:` - when set, every apply returns `{:error, value, state}`, to test
      callers' error handling
    * `in_place:` - a zero-arity function answering `in_place?/1` (defaults to always
      true), to test callers that re-apply a removed ruleset
  """

  @behaviour Gateway.Firewall

  alias Gateway.Firewall

  @impl true
  def init(opts) do
    {floor, cap} = Firewall.ttl_bounds(opts)

    {:ok,
     %{
       clock: Keyword.get(opts, :clock, fn -> System.monotonic_time(:second) end),
       floor: floor,
       cap: cap,
       fail_apply: Keyword.get(opts, :fail_apply),
       in_place: Keyword.get(opts, :in_place, fn -> true end),
       desired: nil,
       apply_count: 0,
       resolved: %{}
     }}
  end

  @impl true
  def apply_desired(_desired, %{fail_apply: reason} = state) when not is_nil(reason) do
    {:error, reason, state}
  end

  def apply_desired(desired, state) do
    {:ok, %{state | desired: desired, apply_count: state.apply_count + 1}}
  end

  @impl true
  def add_resolved(list, state) do
    {valid, invalid} = Firewall.validate_resolved(list)
    now = state.clock.()

    resolved =
      valid
      # ascending ttl, so within one call the longest ttl for an address wins.
      |> Enum.sort_by(fn {_, ttl, _} -> ttl end)
      |> Enum.reduce(prune(state.resolved, now), fn {ip, ttl, tool}, acc ->
        expires_at = now + Firewall.clamp_ttl(ttl, state.floor, state.cap)

        # the latest add sets the expiry, as nftables does on kernel 6.12.
        Map.put(acc, ip, %{tool_id: tool, expires_at: expires_at})
      end)

    state = %{state | resolved: resolved}

    if invalid == [], do: {:ok, state}, else: {:error, {:invalid_entries, invalid}, state}
  end

  @impl true
  def in_place?(state), do: state.in_place.()

  @impl true
  def snapshot(state) do
    now = state.clock.()

    %{
      desired: state.desired,
      apply_count: state.apply_count,
      resolved:
        Map.new(prune(state.resolved, now), fn {ip, e} ->
          {ip, %{tool_id: e.tool_id, expires_in: e.expires_at - now}}
        end)
    }
  end

  defp prune(resolved, now), do: Map.filter(resolved, fn {_, e} -> e.expires_at > now end)
end
