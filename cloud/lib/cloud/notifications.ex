defmodule Cloud.Notifications do
  @moduledoc """
  Tells a tenant's people when something needs their attention: a site was
  locked by an advisory, an advisory waits for a decision, the MSP requested
  a window, a window was approved or rejected, break-glass was opened or
  revoked.

  Notifications go to the tenant's channels (`Cloud.Notifications.Channel`:
  Slack and Teams webhooks, email, SMS). A tenant without any email channel
  also gets an email to each of its admins and approvers, so a fresh tenant
  still hears about advisory locks.

  Every message is one short line and a link into the app
  (`Cloud.Notifications.Message`). It never carries an approve button, an
  action or a token, so a phished or forwarded message cannot unlock
  anything: the reader still has to sign in and approve with a passkey
  (threat model T5).

  `Cloud.Notifications.Dispatcher` listens to every tenant's notifications
  topic and calls `dispatch/1`, which records one
  `Cloud.Notifications.Delivery` per recipient and queues a
  `Cloud.Notifications.Worker` job for it in the same transaction.
  """

  use Ash.Domain, otp_app: :cloud, extensions: [AshAdmin.Domain]

  alias Cloud.Notifications.{Channel, Delivery, Event, Vault, Worker}

  admin do
    show? true
  end

  resources do
    resource Channel do
      define :list_channels, action: :read
      define :get_channel, action: :read, get_by: [:id]
      define :create_channel, action: :create
      define :set_channel_enabled, action: :set_enabled, args: [:enabled]
      define :destroy_channel, action: :destroy
    end

    resource Delivery do
      define :list_deliveries, action: :read
      define :recent_deliveries, action: :recent
      define :get_delivery, action: :read, get_by: [:id]
      define :enqueue_delivery, action: :enqueue
      define :record_delivery_result, action: :record_result
    end
  end

  @doc "The PubSub topic delivery status changes of a tenant are broadcast on."
  @spec deliveries_topic(String.t()) :: String.t()
  def deliveries_topic(tenant_id), do: "tenant:" <> tenant_id <> ":notification_deliveries"

  @doc """
  Queues the notifications for one event (see `Cloud.Notifications.Event`):
  a delivery and a job for each enabled channel of the tenant that receives
  the event's type, plus a fallback email to each admin and approver when
  the tenant has no email channel at all (enabled or not). This is a
  trusted path. Returns `{:ok, deliveries}`.
  """
  @spec dispatch(Event.t()) :: {:ok, [Delivery.t()]} | {:error, term()}
  def dispatch(%{type: type, tenant_id: tenant_id} = event) do
    channels = list_channels!(tenant: tenant_id, authorize?: false)
    matching = Enum.filter(channels, &(&1.enabled and type in &1.event_types))

    fallback =
      if Enum.any?(channels, &(&1.kind == :email)), do: [], else: fallback_recipients(tenant_id)

    rows =
      Enum.map(matching, &channel_row/1) ++
        Enum.map(fallback, &recipient_row/1)

    enqueue(tenant_id, event, rows)
  end

  @doc """
  Queues a test message to one channel, as `actor`. The channel is read as
  the actor first, so only the tenant's admins can send one. Returns
  `{:ok, delivery}`.
  """
  @spec send_test(String.t(), String.t(), keyword()) :: {:ok, Delivery.t()} | {:error, term()}
  def send_test(tenant_id, channel_id, opts) do
    with {:ok, channel} <- get_channel(channel_id, Keyword.merge(opts, tenant: tenant_id)),
         {:ok, [delivery]} <-
           enqueue(tenant_id, %{type: :test, tenant_id: tenant_id}, [channel_row(channel)]) do
      {:ok, delivery}
    end
  end

  @doc """
  The decrypted target of a channel, for the delivery worker only. Returns
  `{:ok, target}` or `:error` when it cannot be decrypted (the key changed).
  """
  @spec target(Channel.t()) :: {:ok, String.t()} | :error
  def target(%Channel{target_ciphertext: ciphertext}), do: Vault.decrypt(ciphertext)

  defp channel_row(channel) do
    %{
      channel_id: channel.id,
      kind: channel.kind,
      channel_name: channel.name,
      target_hint: channel.target_hint
    }
  end

  defp recipient_row(user) do
    email = to_string(user.email)

    %{
      recipient_user_id: user.id,
      kind: :email,
      channel_name: "Fallback email",
      target_hint: Cloud.Notifications.Target.mask(:email, email)
    }
  end

  defp fallback_recipients(tenant_id) do
    Cloud.Accounts.list_memberships!(
      authorize?: false,
      query: [filter: [tenant_id: tenant_id, role: [in: [:admin, :approver]]], load: [:user]]
    )
    |> Enum.map(& &1.user)
    |> Enum.uniq_by(& &1.id)
  end

  defp enqueue(_tenant_id, _event, []), do: {:ok, []}

  defp enqueue(tenant_id, event, rows) do
    args = Event.to_args(event)

    Cloud.Repo.transaction(fn ->
      Enum.map(rows, fn row ->
        attrs = Map.merge(row, %{event_type: event.type, site_id: event[:site_id]})

        with {:ok, delivery} <- enqueue_delivery(attrs, tenant: tenant_id, authorize?: false),
             {:ok, _job} <-
               Oban.insert(
                 Worker.new(%{
                   "delivery_id" => delivery.id,
                   "tenant_id" => tenant_id,
                   "event" => args
                 })
               ) do
          delivery
        else
          {:error, error} -> Cloud.Repo.rollback(error)
        end
      end)
    end)
  end
end
