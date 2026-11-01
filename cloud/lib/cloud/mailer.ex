defmodule Cloud.Mailer do
  @moduledoc """
  The cloud's outbound email (D45).

  Prod sends through Postmark when `POSTMARK_API_KEY` is set (`config/runtime.exs`),
  with no extra dependency: the adapter uses the Req api client. Without a key the
  adapter is `Cloud.Mailer.NotConfigured`, which sends nothing and says so, so a
  release can still run for demos. Dev keeps the local mailbox at `/dev/mailbox` and
  tests use `Swoosh.Adapters.Test`.

  Every email goes out from `from/0`.
  """
  use Swoosh.Mailer, otp_app: :cloud

  @doc """
  The sender every email uses: `config :cloud, :mail_from, {name, address}`
  (prod: `MAIL_FROM` and `MAIL_FROM_NAME`).
  """
  @spec from() :: {String.t(), String.t()}
  def from, do: Application.get_env(:cloud, :mail_from, {"Breakline", "noreply@example.com"})
end
