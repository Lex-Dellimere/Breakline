defmodule Cloud.Notifications.Target do
  @moduledoc """
  Validates and masks channel targets: Slack and Teams webhook URLs, email
  addresses and phone numbers.

  Webhook URLs are checked against a fixed allowlist, so the cloud can never
  be pointed at an internal address (SSRF):

  - Slack incoming webhooks: `https://hooks.slack.com/services/<team>/<bot>/<secret>`,
    the exact host and path shape Slack issues.
  - Teams Workflows webhooks ("When a Teams webhook request is received"):
    `https://<environment>.environment.api.powerplatform.com/powerautomate/automations/direct/...`.
    Office 365 connector webhooks (`*.webhook.office.com`) were retired in
    May 2026, and Microsoft stopped serving Workflows triggers on
    `*.logic.azure.com` on 30 November 2025, so neither is accepted.

  Every webhook URL must be https on port 443, without userinfo or fragment,
  and its host is compared exactly (case-insensitively), so lookalikes such
  as `hooks.slack.com.evil.example`, IP literals and `user@host` tricks fail.
  The hosts are public names run by Slack and Microsoft, which is why the
  host check is enough and the resolved address is not checked again.

  Email addresses get a simple shape check; phone numbers must be E.164
  (`+61412345678`).
  """

  @max_url 4096

  @slack_host "hooks.slack.com"
  @slack_path ~r{\A/services/[A-Za-z0-9]+/[A-Za-z0-9]+/[A-Za-z0-9]+\z}

  # one or more dns labels in front of the fixed power platform suffix
  @teams_host ~r/\A(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+environment\.api\.powerplatform\.com\z/
  @teams_path_prefix "/powerautomate/automations/direct/"

  @email ~r/\A[^\s@<>"',;]+@[^\s@<>"',;]+\.[^\s@<>"',;]+\z/
  @phone ~r/\A\+[1-9][0-9]{6,14}\z/

  @type kind :: :slack | :teams | :email | :sms

  @doc """
  Checks a target for a channel kind. Returns `{:ok, normalised}` (trimmed;
  emails lowercased) or `{:error, message}`.
  """
  @spec validate(kind(), term()) :: {:ok, String.t()} | {:error, String.t()}
  def validate(kind, target) when is_binary(target) do
    target = String.trim(target)

    cond do
      target == "" -> {:error, "is required"}
      String.match?(target, ~r/[\s\x00-\x1f\x7f]/u) -> {:error, "must not contain spaces"}
      true -> do_validate(kind, target)
    end
  end

  def validate(_kind, _target), do: {:error, "is required"}

  defp do_validate(kind, url) when kind in [:slack, :teams] do
    with :ok <- check(byte_size(url) <= @max_url, "is too long"),
         {:ok, uri} <- parse(url),
         :ok <- check(uri.scheme == "https", "must be an https url"),
         :ok <- check(uri.userinfo == nil, "must not contain a user name"),
         :ok <- check(uri.port in [nil, 443], "must use the standard https port"),
         :ok <- check(uri.fragment == nil, "must not contain a fragment"),
         host = String.downcase(uri.host || ""),
         :ok <- check(not ip_literal?(host), "must not be an ip address"),
         :ok <- webhook_shape(kind, host, uri) do
      {:ok, url}
    end
  end

  defp do_validate(:email, email) do
    if String.match?(email, @email) and byte_size(email) <= 254,
      do: {:ok, String.downcase(email)},
      else: {:error, "must be an email address"}
  end

  defp do_validate(:sms, phone) do
    if String.match?(phone, @phone),
      do: {:ok, phone},
      else: {:error, "must be a phone number in international format, like +61412345678"}
  end

  defp do_validate(_kind, _target), do: {:error, "has an unknown channel kind"}

  defp webhook_shape(:slack, host, uri) do
    with :ok <- check(host == @slack_host, "must be a Slack incoming webhook on hooks.slack.com"),
         :ok <- check(uri.query == nil, "must not have a query string") do
      check(
        is_binary(uri.path) and String.match?(uri.path, @slack_path),
        "must be a Slack incoming webhook url (https://hooks.slack.com/services/...)"
      )
    end
  end

  defp webhook_shape(:teams, host, uri) do
    with :ok <-
           check(
             String.match?(host, @teams_host),
             "must be a Teams Workflows webhook on environment.api.powerplatform.com"
           ) do
      check(
        is_binary(uri.path) and String.starts_with?(uri.path, @teams_path_prefix) and
          not String.contains?(uri.path, ["/../", "/./", "//"]),
        "must be a Teams Workflows webhook url (.../powerautomate/automations/direct/...)"
      )
    end
  end

  defp parse(url) do
    case URI.new(url) do
      {:ok, %URI{host: host} = uri} when is_binary(host) and host != "" -> {:ok, uri}
      _ -> {:error, "must be a valid url"}
    end
  end

  defp ip_literal?(host) do
    host = host |> String.trim_leading("[") |> String.trim_trailing("]")
    match?({:ok, _}, :inet.parse_address(String.to_charlist(host)))
  end

  defp check(true, _message), do: :ok
  defp check(_false, message), do: {:error, message}

  @doc """
  A form of the target that is safe to show: the webhook host with the last
  four characters of its path, the email's first letter and domain, the
  phone number's country prefix and last three digits.
  """
  @spec mask(kind(), String.t()) :: String.t()
  def mask(kind, url) when kind in [:slack, :teams] do
    host = URI.parse(url).host || "webhook"
    host <> "/…" <> String.slice(url, -4, 4)
  end

  def mask(:email, email) do
    case String.split(email, "@", parts: 2) do
      [local, domain] -> String.first(local) <> "•••@" <> domain
      _ -> "•••"
    end
  end

  def mask(:sms, phone) do
    String.slice(phone, 0, 3) <> "•••••" <> String.slice(phone, -3, 3)
  end
end
