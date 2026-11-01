defmodule Gateway.Status do
  @moduledoc """
  The human-readable status that `breakline-gateway status` prints on a pilot box.

  The wrapper runs `print/0` on the running node through the release's rpc
  (`bin/gateway rpc 'Gateway.Status.print()'`). `render/0` gathers
  `Gateway.Enforcer.status/0` and `Gateway.Uplink.status/0`, and `format/2` turns
  them into text, so it can be tested without a running tree.
  """

  alias Gateway.Enforcer

  @doc "Prints `render/0`."
  @spec print() :: :ok
  def print, do: IO.puts(render())

  @doc """
  The status of the running gateway as text. A stopped enforcer shows as not
  running instead of raising.
  """
  @spec render() :: String.t()
  def render do
    enforcer =
      try do
        Enforcer.status()
      catch
        :exit, _ -> nil
      end

    uplink =
      Gateway.Uplink.status()
      |> Map.put(:configured?, Application.get_env(:gateway, :uplink) != nil)

    format(enforcer, uplink)
  end

  @doc """
  Formats an enforcer status (or nil when it is not running) and an uplink status
  with a `:configured?` key.
  """
  @spec format(Enforcer.status() | nil, map()) :: String.t()
  def format(enforcer, uplink) do
    (["enforcer"] ++ enforcer_lines(enforcer) ++ ["", "uplink"] ++ uplink_lines(uplink))
    |> Enum.join("\n")
  end

  defp enforcer_lines(nil), do: [row("state", "not running")]

  defp enforcer_lines(s) do
    [
      row("state", "#{s.state} (#{reason(s.reason)})"),
      row("mode", s.mode),
      row("policy version", policy_version(s)),
      row("clock synced", yes_no(s.clock_synced?)),
      row("next change", time(s.next_change)),
      row("last applied", time(s.last_applied_at)),
      row("firewall", firewall(s.firewall))
    ]
  end

  defp uplink_lines(%{configured?: false}),
    do: [row("status", "not configured (no BREAKLINE_UPLINK_URL)")]

  defp uplink_lines(u) do
    [
      row("status", uplink_state(u)),
      row("url", u.url || "-"),
      row("last heartbeat", time(u.last_heartbeat_at)),
      row("events in flight", u.events_in_flight),
      row("audit ack", audit_ack(u.audit_ack)),
      row("cool-offs", cool_offs(u))
    ] ++ if(u.last_error, do: [row("last error", inspect(u.last_error))], else: [])
  end

  defp row(label, value), do: "  " <> String.pad_trailing(label <> ":", 18) <> to_string(value)

  defp reason(reason) do
    case Enforcer.describe_reason(reason) do
      %{"rule" => rule} = map when map_size(map) == 1 ->
        rule

      %{"rule" => rule} = map ->
        details =
          map
          |> Map.delete("rule")
          |> Enum.reject(fn {_k, v} -> is_nil(v) end)
          |> Enum.sort()
          |> Enum.map_join(", ", fn {k, v} -> "#{k} #{v}" end)

        "#{rule}: #{details}"
    end
  end

  defp policy_version(%{policy_version: nil, last_version: last}),
    do: "none (last accepted #{last})"

  defp policy_version(%{policy_version: v}), do: v

  defp firewall(%{running?: false} = fw), do: "not running" <> fw_error(fw)

  defp firewall(fw) do
    sync = if fw.in_sync?, do: "in sync", else: "not in sync"
    impl = fw.impl |> inspect() |> String.replace_prefix("Gateway.Firewall.", "")

    "#{impl}, #{sync}, #{fw.apply_count || 0} applies, #{fw.resolved_count || 0} resolved ips" <>
      fw_error(fw)
  end

  defp fw_error(%{last_error: nil}), do: ""
  defp fw_error(%{last_error: e}), do: ", last error #{inspect(e)}"

  defp uplink_state(%{running?: false}), do: "not running"
  defp uplink_state(%{cooling_off?: true}), do: "cooling off after a crash loop"
  defp uplink_state(%{joined?: true}), do: "connected, joined"
  defp uplink_state(%{connected?: true}), do: "connected, not joined"
  defp uplink_state(%{attempt: n}), do: "disconnected (attempt #{n})"

  defp audit_ack(nil), do: "none"
  defp audit_ack({seq, _hash}), do: "seq #{seq}"

  defp cool_offs(u), do: Map.get(u, :cool_offs, 0)

  defp yes_no(true), do: "yes"
  defp yes_no(_), do: "no"

  defp time(nil), do: "-"
  defp time(%DateTime{} = t), do: DateTime.to_iso8601(t)
end
