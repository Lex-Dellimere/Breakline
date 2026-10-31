defmodule Cloud.Notifications.Worker do
  @moduledoc """
  Sends one `Cloud.Notifications.Delivery`: builds the message for its event
  (`Cloud.Notifications.Message`) and posts it to the channel's webhook,
  emails it or texts it.

  Job args are the delivery id, the tenant id and the event's ids
  (`Cloud.Notifications.Event.to_args/1`); the target is read and decrypted
  from the channel at send time, so no secret is ever stored in a job.

  Failures are retried up to 5 attempts with a growing backoff (30 s, 2 min,
  10 min, 30 min). Each failed attempt records its error on the delivery;
  the last one marks it `:failed`. Some failures are permanent and fail the
  delivery at once (the job is cancelled): the channel was removed or
  disabled, its target cannot be decrypted or no longer passes validation,
  or the webhook answered a 4xx other than 408 or 429 (Slack answers 404
  or 410 for a removed webhook). Every status change is broadcast on
  `Cloud.Notifications.deliveries_topic/1`.
  """

  use Oban.Worker, queue: :notifications, max_attempts: 5

  alias Cloud.Notifications
  alias Cloud.Notifications.{Delivery, Event, Message, SMS, Webhook}

  import Swoosh.Email

  @backoff [30, 120, 600, 1800]

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}),
    do: Enum.at(@backoff, attempt - 1, List.last(@backoff))

  @impl Oban.Worker
  def perform(%Oban.Job{args: args, attempt: attempt, max_attempts: max_attempts}) do
    %{"delivery_id" => delivery_id, "tenant_id" => tenant_id} = args
    event = Event.from_args(Map.get(args, "event", %{}))

    case Notifications.get_delivery(delivery_id,
           tenant: tenant_id,
           authorize?: false,
           not_found_error?: false
         ) do
      {:ok, %Delivery{status: :pending} = delivery} ->
        delivery
        |> send_delivery(Map.put(event, :tenant_id, tenant_id))
        |> finish(delivery, attempt, max_attempts)

      {:ok, %Delivery{}} ->
        :ok

      _ ->
        {:cancel, "delivery not found"}
    end
  end

  defp finish(:ok, delivery, attempt, _max) do
    record(delivery, %{
      status: :sent,
      attempts: attempt,
      last_error: nil,
      sent_at: DateTime.utc_now()
    })

    :ok
  end

  defp finish({:error, reason}, delivery, attempt, max) do
    message = error_message(reason)

    cond do
      permanent?(reason) ->
        record(delivery, %{status: :failed, attempts: attempt, last_error: message})
        {:cancel, message}

      attempt >= max ->
        record(delivery, %{status: :failed, attempts: attempt, last_error: message})
        {:error, message}

      true ->
        record(delivery, %{status: :pending, attempts: attempt, last_error: message})
        {:error, message}
    end
  end

  defp record(delivery, attrs) do
    {:ok, delivery} =
      Notifications.record_delivery_result(delivery, attrs,
        tenant: delivery.tenant_id,
        authorize?: false
      )

    Phoenix.PubSub.broadcast(
      Cloud.PubSub,
      Notifications.deliveries_topic(delivery.tenant_id),
      {:delivery, %{id: delivery.id, status: delivery.status}}
    )

    delivery
  end

  # fallback email to a member, who has no channel
  defp send_delivery(%Delivery{channel_id: nil, recipient_user_id: user_id}, event)
       when is_binary(user_id) do
    case Ash.get(Cloud.Accounts.User, user_id, authorize?: false) do
      {:ok, user} -> send_email(to_string(user.email), Message.build(event))
      _ -> {:error, {:permanent, "recipient no longer exists"}}
    end
  end

  defp send_delivery(%Delivery{channel_id: nil}, _event),
    do: {:error, {:permanent, "channel was removed"}}

  defp send_delivery(%Delivery{channel_id: channel_id, tenant_id: tenant_id}, event) do
    with {:ok, %{} = channel} <-
           Notifications.get_channel(channel_id,
             tenant: tenant_id,
             authorize?: false,
             not_found_error?: false
           ),
         :ok <- check_enabled(channel, event),
         {:ok, target} <- decrypt(channel) do
      deliver(channel.kind, target, Message.build(event))
    else
      {:ok, nil} -> {:error, {:permanent, "channel was removed"}}
      {:error, _reason} = error -> error
    end
  end

  # a test message goes out even on a disabled channel, so it can be checked first
  defp check_enabled(%{enabled: true}, _event), do: :ok
  defp check_enabled(_channel, %{type: :test}), do: :ok
  defp check_enabled(_channel, _event), do: {:error, {:permanent, "channel is disabled"}}

  defp decrypt(channel) do
    case Notifications.target(channel) do
      {:ok, target} -> {:ok, target}
      :error -> {:error, {:permanent, "target cannot be decrypted, add the channel again"}}
    end
  end

  defp deliver(:slack, url, message), do: Webhook.post(:slack, url, Message.slack(message))
  defp deliver(:teams, url, message), do: Webhook.post(:teams, url, Message.teams(message))
  defp deliver(:email, address, message), do: send_email(address, message)
  defp deliver(:sms, phone, message), do: SMS.deliver(phone, Message.sms(message))

  defp send_email(address, message) do
    content = Message.email(message)

    email =
      new()
      |> from(
        Application.get_env(:cloud, :notifications_from, {"Breakline", "noreply@example.com"})
      )
      |> to(address)
      |> subject(content.subject)
      |> text_body(content.text)
      |> html_body(content.html)

    case Cloud.Mailer.deliver(email) do
      {:ok, _} -> :ok
      {:error, _reason} -> {:error, :email_failed}
    end
  end

  defp permanent?({:permanent, _message}), do: true
  defp permanent?(:invalid_target), do: true

  defp permanent?({:http_status, status}),
    do: status in 400..499 and status not in [408, 429]

  defp permanent?(_reason), do: false

  defp error_message({:permanent, message}), do: message
  defp error_message(:invalid_target), do: "target is no longer an allowed webhook url"
  defp error_message({:http_status, status}), do: "http status #{status}"
  defp error_message({:transport, reason}), do: "connection failed: #{reason}"
  defp error_message(:email_failed), do: "email could not be sent"
  defp error_message(:dev_sms_not_started), do: "dev sms adapter is not running"
  defp error_message(_reason), do: "delivery failed"
end
