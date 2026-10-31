defmodule Cloud.Notifications.SMS.Dev do
  @moduledoc """
  The dev and test SMS adapter: sends nothing, logs each message and keeps
  the last hundred in memory for the `/dev/sms` page (`messages/0`).

  `Cloud.Application` starts it when it is the configured adapter.
  """

  @behaviour Cloud.Notifications.SMS

  use Agent

  require Logger

  @keep 100

  @doc false
  def start_link(_opts), do: Agent.start_link(fn -> [] end, name: __MODULE__)

  @impl Cloud.Notifications.SMS
  def deliver(to, body) do
    case Process.whereis(__MODULE__) do
      nil ->
        {:error, :dev_sms_not_started}

      _pid ->
        Logger.info("dev sms to #{to}: #{body}")
        message = %{to: to, body: body, at: DateTime.utc_now()}
        Agent.update(__MODULE__, &Enum.take([message | &1], @keep))
    end
  end

  @doc "The kept messages, newest first."
  @spec messages() :: [%{to: String.t(), body: String.t(), at: DateTime.t()}]
  def messages do
    if Process.whereis(__MODULE__), do: Agent.get(__MODULE__, & &1), else: []
  end

  @doc "Forgets the kept messages."
  @spec clear() :: :ok
  def clear do
    if Process.whereis(__MODULE__), do: Agent.update(__MODULE__, fn _ -> [] end), else: :ok
  end
end
