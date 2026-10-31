defmodule Gateway.Uplink.Encode do
  @moduledoc """
  Turns gateway terms into json-safe maps for the uplink: only maps with string
  keys, lists, strings, numbers, booleans and nil, so any JSON encoder accepts the
  result and the cloud reads the same shape whatever the term was.

  The general rules (`json_safe/1`):

    * atom keys become strings, without a trailing `?` (`clock_synced?` is
      `"clock_synced"`)
    * `DateTime`, `NaiveDateTime` and `Date` become iso8601 strings
    * an ip address tuple becomes its string form
    * `true`, `false` and `nil` stay; other atoms become strings, modules without
      the `Elixir.` prefix
    * other tuples become lists, and pids, refs and functions their inspected form

  `status/1` and `event/1` add the shapes that matter to the cloud: lock reasons
  through `Gateway.Enforcer.describe_reason/1`, DNS match tags as maps with a
  `"kind"`, and rejection reasons as strings.
  """

  alias Gateway.Enforcer

  @type json :: nil | boolean() | number() | String.t() | [json()] | %{String.t() => json()}

  @doc """
  Encodes `Gateway.Enforcer.status/0`: state, reason, versions, mode, clock sync,
  next change, last apply and the firewall summary.
  """
  @spec status(Enforcer.status()) :: %{String.t() => json()}
  def status(status) when is_map(status) do
    firewall = Map.get(status, :firewall) || %{}

    %{
      "state" => json_safe(status.state),
      "reason" => reason(status.reason),
      "policy_version" => status.policy_version,
      "last_version" => status.last_version,
      "mode" => json_safe(status.mode),
      "clock_synced" => status.clock_synced?,
      "next_change" => json_safe(status.next_change),
      "last_applied_at" => json_safe(status.last_applied_at),
      "firewall" =>
        firewall
        |> Map.delete(:last_error)
        |> json_safe()
        |> Map.put("last_error", error_string(Map.get(firewall, :last_error)))
    }
  end

  @doc """
  Encodes a `Gateway.Events` event. `id` is added as `"id"` so the cloud can drop a
  duplicate of an event it already has (the uplink sends at least once).
  """
  @spec event(map(), String.t() | nil) :: %{String.t() => json()}
  def event(event, id \\ nil) when is_map(event) do
    type = Map.get(event, :type)

    encoded =
      Map.new(event, fn
        {:match, match} -> {"match", match(match)}
        {:reason, r} when type == :command_rejected -> {"reason", rejection(r)}
        {:reason, r} -> {"reason", reason(r)}
        {key, value} -> {key(key), json_safe(value)}
      end)

    if id, do: Map.put(encoded, "id", id), else: encoded
  end

  @doc """
  Encodes a DNS match: a catalog tool id, `{:site_host, host}`,
  `{:cname, target, tag}`, `{:doh, name}` or `{:canary, name}`.
  """
  @spec match(term()) :: %{String.t() => json()}
  def match(tool_id) when is_binary(tool_id), do: %{"kind" => "tool", "tag" => tool_id}

  def match({:site_host, host} = tag),
    do: %{"kind" => "site_host", "name" => host, "tag" => tag(tag)}

  def match({:cname, target, tag}),
    do: %{"kind" => "cname", "name" => target, "tag" => tag(tag)}

  def match({kind, name}) when kind in [:doh, :canary] and is_binary(name),
    do: %{"kind" => Atom.to_string(kind), "name" => name}

  def match(other), do: %{"kind" => "other", "value" => json_safe(other)}

  # a tag as the firewall spells it: the tool id, or "site_host:" <> host
  defp tag({:site_host, host}), do: "site_host:" <> host
  defp tag(tool_id) when is_binary(tool_id), do: tool_id
  defp tag(other), do: inspect(other)

  @doc """
  Encodes an enforcer reason (`t:Gateway.Enforcer.reason/0`) through
  `Gateway.Enforcer.describe_reason/1`. Anything it does not know is encoded with
  `json_safe/1`.
  """
  @spec reason(term()) :: json()
  def reason(nil), do: nil

  def reason(reason) do
    Enforcer.describe_reason(reason)
  rescue
    _ -> json_safe(reason)
  end

  @doc """
  The short string for a rejected command: `"stale_version"`, `"invalid_policy"`
  and so on, the same names the audit chain uses.
  """
  @spec rejection_reason(term()) :: String.t()
  def rejection_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  def rejection_reason({name, _detail}) when is_atom(name), do: Atom.to_string(name)
  def rejection_reason(other), do: inspect(other)

  defp rejection(reason) do
    case reason do
      {_name, detail} -> %{"reason" => rejection_reason(reason), "details" => inspect(detail)}
      _ -> %{"reason" => rejection_reason(reason)}
    end
  end

  defp error_string(nil), do: nil
  defp error_string(error), do: inspect(error)

  @doc "Converts any term to a json-safe value; see the moduledoc for the rules."
  @spec json_safe(term()) :: json()
  def json_safe(value) when is_binary(value) or is_number(value), do: value
  def json_safe(value) when is_boolean(value) or is_nil(value), do: value
  def json_safe(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  def json_safe(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
  def json_safe(%Date{} = d), do: Date.to_iso8601(d)
  def json_safe(%_{} = struct), do: struct |> Map.from_struct() |> json_safe()
  def json_safe(value) when is_atom(value), do: atom(value)

  def json_safe(value) when is_map(value),
    do: Map.new(value, fn {k, v} -> {key(k), json_safe(v)} end)

  def json_safe(value) when is_list(value) do
    if List.improper?(value), do: inspect(value), else: Enum.map(value, &json_safe/1)
  end

  def json_safe(value) when is_tuple(value) do
    if ip?(value),
      do: value |> :inet.ntoa() |> to_string(),
      else: value |> Tuple.to_list() |> Enum.map(&json_safe/1)
  end

  def json_safe(value), do: inspect(value)

  defp key(k) when is_atom(k), do: k |> Atom.to_string() |> String.trim_trailing("?")
  defp key(k) when is_binary(k), do: k
  defp key(k), do: inspect(k)

  defp atom(a) do
    case Atom.to_string(a) do
      "Elixir." <> name -> name
      name -> name
    end
  end

  defp ip?({a, b, c, d}), do: Enum.all?([a, b, c, d], &(is_integer(&1) and &1 in 0..255))

  defp ip?({_, _, _, _, _, _, _, _} = t),
    do: t |> Tuple.to_list() |> Enum.all?(&(is_integer(&1) and &1 in 0..65_535))

  defp ip?(_), do: false
end
