defmodule Cloud.Notifications.Event do
  @moduledoc """
  Turns the messages broadcast on a tenant's notifications topic into
  notification events.

  - `{:advisory, %{status: :locked}}` becomes `:advisory_locked` and
    `status: :pending` becomes `:advisory_pending`. A dismissal is not
    notified: it only leaves access as it was.
  - `{:notification, %{type: type}}` with one of the window and break-glass
    types keeps its type.

  Anything else is ignored. An event keeps only a few known id and name
  fields, as strings, so it can travel in Oban job args: nothing a broadcast
  happens to carry (a struct, a token) ever reaches a job or a message.
  """

  @types [
    :advisory_locked,
    :advisory_pending,
    :window_requested,
    :window_approved,
    :window_rejected,
    :break_glass_opened,
    :break_glass_revoked
  ]

  @broadcast_types [
    :window_requested,
    :window_approved,
    :window_rejected,
    :break_glass_opened,
    :break_glass_revoked
  ]

  # the only fields an event keeps
  @fields [
    :site_id,
    :advisory_id,
    :window_id,
    :break_glass_id,
    :msp_contact_id,
    :msp_name,
    :requested_by
  ]

  @type t :: %{
          required(:type) => atom(),
          required(:tenant_id) => String.t(),
          optional(atom()) => String.t()
        }

  @doc "Every event type a channel can receive, in display order."
  @spec types() :: [atom()]
  def types, do: @types

  @doc "A short label for an event type, for the settings page."
  @spec label(atom()) :: String.t()
  def label(:advisory_locked), do: "Site locked by an advisory"
  def label(:advisory_pending), do: "Advisory waiting for a decision"
  def label(:window_requested), do: "Window requested"
  def label(:window_approved), do: "Window approved"
  def label(:window_rejected), do: "Window rejected"
  def label(:break_glass_opened), do: "Break-glass opened"
  def label(:break_glass_revoked), do: "Break-glass revoked"
  def label(:test), do: "Test message"

  @doc "The event a broadcast message stands for, or `:ignore`."
  @spec from_message(term()) :: {:ok, t()} | :ignore
  def from_message({:advisory, %{tenant_id: tenant_id, status: status} = payload})
      when is_binary(tenant_id) do
    case status do
      :locked -> {:ok, build(:advisory_locked, tenant_id, payload)}
      :pending -> {:ok, build(:advisory_pending, tenant_id, payload)}
      _ -> :ignore
    end
  end

  def from_message({:notification, %{type: type, tenant_id: tenant_id} = payload})
      when type in @broadcast_types and is_binary(tenant_id) do
    {:ok, build(type, tenant_id, payload)}
  end

  def from_message(_message), do: :ignore

  defp build(type, tenant_id, payload) do
    fields =
      for field <- @fields,
          value = Map.get(payload, field),
          is_binary(value) and value != "",
          into: %{},
          do: {field, String.slice(value, 0, 200)}

    Map.merge(fields, %{type: type, tenant_id: tenant_id})
  end

  @doc "The event as json-safe job args (string keys and values)."
  @spec to_args(t()) :: map()
  def to_args(event),
    do: Map.new(event, fn {key, value} -> {to_string(key), to_string(value)} end)

  @doc "An event back from `to_args/1`; unknown keys and types are dropped."
  @spec from_args(map()) :: t()
  def from_args(args) do
    known = Map.new([:type, :tenant_id | @fields], &{to_string(&1), &1})

    Enum.reduce(args, %{}, fn {key, value}, acc ->
      case Map.fetch(known, key) do
        {:ok, :type} -> Map.put(acc, :type, type_from_string(value))
        {:ok, field} -> Map.put(acc, field, value)
        :error -> acc
      end
    end)
  end

  defp type_from_string(value) do
    Enum.find([:test | @types], :unknown, &(Atom.to_string(&1) == value))
  end
end
