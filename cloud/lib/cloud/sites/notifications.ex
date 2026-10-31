defmodule Cloud.Sites.Notifications do
  @moduledoc """
  Events for the tenant's notification channels (Slack, Teams, email, SMS),
  broadcast on `Cloud.Advisories.notifications_topic/1`
  (`"tenant:<tenant_id>:notifications"`) after the action that caused them
  committed (`Cloud.Sites.Changes.Notify`).

  Each is `{:notification, %{type: type, tenant_id: ..., site_id: ..., ...}}`
  with:

  - `:window_requested`, `:window_approved`, `:window_rejected`:
    `window_id`, `site_name`, `time_zone`, `contact_name` (nil when no
    contact requested it), `starts_at` and `ends_at` (local naive datetimes
    in the site's zone, nil for a recurring window), `reason`, `note` (the
    rejection note), `by` (the deciding user's email, nil for a request) and
    `path` (`"/requests"`)
  - `:break_glass_opened`, `:break_glass_revoked`: `break_glass_id`,
    `site_name`, `time_zone`, `until` (utc), `until_local` (naive, site
    zone), `by` (the user's email) and `path` (the site page)

  Payloads hold no secrets and no way to act: a notification is a pointer to
  a page where the approver signs in and decides (threat model T5).
  """

  alias Cloud.Accounts.User
  alias Cloud.Sites
  alias Cloud.Sites.{BreakGlass, Window}

  @types [
    :window_requested,
    :window_approved,
    :window_rejected,
    :break_glass_opened,
    :break_glass_revoked
  ]

  @doc "The notification types this module sends."
  def types, do: @types

  @doc "Broadcasts the notification for `record`. Call it only after its transaction committed."
  @spec broadcast(atom(), Window.t() | BreakGlass.t(), term()) :: :ok | {:error, term()}
  def broadcast(type, record, actor) when type in @types do
    Phoenix.PubSub.broadcast(
      Cloud.PubSub,
      Cloud.Advisories.notifications_topic(record.tenant_id),
      {:notification, payload(type, record, actor)}
    )
  end

  @doc "The payload of a notification (see the module doc)."
  @spec payload(atom(), Window.t() | BreakGlass.t(), term()) :: map()
  def payload(type, %Window{} = window, actor) do
    site = site(window.site_id)

    %{
      type: type,
      tenant_id: window.tenant_id,
      site_id: window.site_id,
      site_name: site && site.name,
      time_zone: site && site.time_zone,
      window_id: window.id,
      contact_name: contact_name(window),
      starts_at: window.starts_at,
      ends_at: window.ends_at,
      reason: window.reason,
      note: window.rejection_note,
      by: email(actor),
      path: "/requests"
    }
  end

  def payload(type, %BreakGlass{} = break_glass, actor) do
    site = site(break_glass.site_id)

    %{
      type: type,
      tenant_id: break_glass.tenant_id,
      site_id: break_glass.site_id,
      site_name: site && site.name,
      time_zone: site && site.time_zone,
      break_glass_id: break_glass.id,
      until: break_glass.until,
      until_local: site && local(break_glass.until, site.time_zone),
      by: email(actor),
      path: "/sites/" <> break_glass.site_id
    }
  end

  # trusted reads for the payload of a change that was already authorised
  defp site(site_id) do
    case Sites.get_site(site_id, authorize?: false, not_found_error?: false) do
      {:ok, %{} = site} -> site
      _ -> nil
    end
  end

  defp contact_name(%Window{requested_by_id: nil}), do: nil

  defp contact_name(%Window{requested_by_id: id, tenant_id: tenant_id}) do
    case Sites.get_msp_contact(id, tenant: tenant_id, authorize?: false, not_found_error?: false) do
      {:ok, %{name: name}} -> name
      _ -> nil
    end
  end

  defp email(%User{email: email}) when not is_nil(email), do: to_string(email)
  defp email(_actor), do: nil

  defp local(utc, time_zone) do
    utc |> DateTime.shift_zone!(time_zone, Tz.TimeZoneDatabase) |> DateTime.to_naive()
  end
end
