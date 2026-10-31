defmodule Cloud.Notifications.Message do
  @moduledoc """
  Builds the one line a notification says and the payload for each channel
  kind.

  A message is a sentence plus a link into the app, and nothing else:

      Breakline: Parramatta clinic was locked by advisory CISA KEV CVE-2026-18577. Review: https://.../advisories

  Links go to a page (`/advisories`, `/requests`, `/sites/:id`, `/sites`),
  never to an action endpoint, and never carry a token or a query string.
  The payloads have no buttons or actions:

  - Slack: `%{text: line}` only, no blocks.
  - Teams: a message with one Adaptive Card holding one `TextBlock`, the
    shape the Workflows "send webhook alerts to a channel" template posts. No
    `actions`, no `selectAction`.
  - Email: a plain text body and a simple html body with the same sentence
    and a plain link.
  - SMS: the line itself.

  Names that come from people (site, MSP contact, advisory titles) are
  reduced to plain text before they go in: markup characters that Slack,
  Teams markdown or html would treat as a link or mention are dropped and
  the length is capped, so a site named like a link cannot smuggle one in.
  """

  alias Cloud.Notifications.Event

  @enforce_keys [:sentence, :url, :link_label]
  defstruct [:sentence, :url, :link_label]

  @type t :: %__MODULE__{sentence: String.t(), url: String.t(), link_label: String.t()}

  @doc "Builds the message for an event, reading names with trusted lookups."
  @spec build(Event.t()) :: t()
  def build(%{type: :test, tenant_id: tenant_id}) do
    %__MODULE__{
      sentence: "this is a test notification for #{tenant_name(tenant_id)}.",
      url: url("/sites"),
      link_label: "Sites"
    }
  end

  def build(%{type: type} = event) when type in [:advisory_locked, :advisory_pending] do
    site = site_name(event)
    advisory = advisory_label(event)

    sentence =
      case type do
        :advisory_locked -> "#{site} was locked by advisory #{advisory}."
        :advisory_pending -> "advisory #{advisory} affects #{site} and needs a decision."
      end

    %__MODULE__{sentence: sentence, url: url("/advisories"), link_label: "Review"}
  end

  def build(%{type: :window_requested} = event) do
    %__MODULE__{
      sentence: "#{msp_name(event)} requested a window for #{site_name(event)}.",
      url: url("/requests"),
      link_label: "Review"
    }
  end

  def build(%{type: type} = event) when type in [:window_approved, :window_rejected] do
    verb = if type == :window_approved, do: "approved", else: "rejected"

    %__MODULE__{
      sentence: "a window for #{site_name(event)} was #{verb}.",
      url: url("/requests"),
      link_label: "Review"
    }
  end

  def build(%{type: :break_glass_opened} = event) do
    %__MODULE__{
      sentence: "break-glass access was opened for #{site_name(event)}.",
      url: site_url(event),
      link_label: "Review"
    }
  end

  def build(%{type: :break_glass_revoked} = event) do
    %__MODULE__{
      sentence: "break-glass access for #{site_name(event)} was revoked.",
      url: site_url(event),
      link_label: "Review"
    }
  end

  @doc "The whole line: `Breakline: <sentence> <label>: <url>`."
  @spec line(t()) :: String.t()
  def line(%__MODULE__{} = message),
    do: "Breakline: #{message.sentence} #{message.link_label}: #{message.url}"

  @doc "The Slack incoming webhook payload."
  @spec slack(t()) :: map()
  def slack(message), do: %{"text" => slack_escape(line(message))}

  @doc "The Teams Workflows webhook payload."
  @spec teams(t()) :: map()
  def teams(message) do
    %{
      "type" => "message",
      "attachments" => [
        %{
          "contentType" => "application/vnd.microsoft.card.adaptive",
          "contentUrl" => nil,
          "content" => %{
            "$schema" => "http://adaptivecards.io/schemas/adaptive-card.json",
            "type" => "AdaptiveCard",
            "version" => "1.2",
            "body" => [
              %{
                "type" => "TextBlock",
                "text" =>
                  "Breakline: #{message.sentence} #{message.link_label}: " <>
                    "[#{message.url}](#{message.url})",
                "wrap" => true
              }
            ]
          }
        }
      ]
    }
  end

  @doc "The email's subject, text body and html body."
  @spec email(t()) :: %{subject: String.t(), text: String.t(), html: String.t()}
  def email(message) do
    url = html_escape(message.url)

    %{
      subject: "Breakline: " <> capitalise(String.trim_trailing(message.sentence, ".")),
      text: line(message) <> "\n",
      html: """
      <p>Breakline: #{html_escape(message.sentence)}</p>
      <p>#{html_escape(message.link_label)}: <a href="#{url}">#{url}</a></p>
      """
    }
  end

  @doc "The SMS body."
  @spec sms(t()) :: String.t()
  def sms(message), do: line(message)

  @doc """
  Reduces a name from user input to plain text: markup and control
  characters are dropped, whitespace collapsed and the length capped.
  """
  @spec plain(String.t() | nil, String.t()) :: String.t()
  def plain(value, fallback \\ "a site")

  def plain(value, fallback) when is_binary(value) do
    value
    |> String.replace(~r/[<>\[\]()*_~`|\\{}#!@&"]/u, "")
    |> String.replace(~r/[\p{C}\s]+/u, " ")
    |> String.trim()
    |> String.slice(0, 80)
    |> case do
      "" -> fallback
      text -> text
    end
  end

  def plain(_value, fallback), do: fallback

  # names, read with trusted lookups

  defp site_name(%{site_id: site_id, tenant_id: tenant_id}) when is_binary(site_id) do
    case Cloud.Sites.get_site(site_id,
           tenant: tenant_id,
           authorize?: false,
           not_found_error?: false
         ) do
      {:ok, %{tenant_id: ^tenant_id, name: name}} -> plain(name)
      _ -> "a site"
    end
  end

  defp site_name(_event), do: "a site"

  defp site_url(%{site_id: site_id}) when is_binary(site_id) do
    case Ecto.UUID.cast(site_id) do
      {:ok, uuid} -> url("/sites/" <> uuid)
      :error -> url("/sites")
    end
  end

  defp site_url(_event), do: url("/sites")

  defp advisory_label(%{advisory_id: id}) when is_binary(id) do
    case Ash.get(Cloud.Advisories.Advisory, id, authorize?: false) do
      {:ok, %{} = advisory} ->
        source = if advisory.source == :kev, do: "CISA KEV", else: "ACSC"

        case advisory.cves do
          [cve | _] -> "#{source} #{plain(cve, "")}" |> String.trim()
          [] -> "#{source} #{plain(advisory.title, "")}" |> String.trim()
        end

      _ ->
        "from a threat feed"
    end
  end

  defp advisory_label(_event), do: "from a threat feed"

  defp msp_name(%{msp_contact_id: id, tenant_id: tenant_id}) when is_binary(id) do
    case contact(id, tenant_id) do
      nil -> "Your MSP contact"
      name -> name
    end
  end

  defp msp_name(%{window_id: id, tenant_id: tenant_id} = event) when is_binary(id) do
    with {:ok, %{requested_by_id: contact_id}} when is_binary(contact_id) <-
           Cloud.Sites.get_window(id,
             tenant: tenant_id,
             authorize?: false,
             not_found_error?: false
           ),
         name when is_binary(name) <- contact(contact_id, tenant_id) do
      name
    else
      _ -> event |> Map.delete(:window_id) |> msp_name()
    end
  end

  defp msp_name(%{msp_name: name}) when is_binary(name), do: plain(name, "Your MSP contact")
  defp msp_name(%{requested_by: name}) when is_binary(name), do: plain(name, "Your MSP contact")
  defp msp_name(_event), do: "Your MSP contact"

  defp contact(id, tenant_id) do
    with {:ok, _} <- Ecto.UUID.cast(id),
         [%{name: name}] <-
           Cloud.Sites.list_msp_contacts!(
             tenant: tenant_id,
             authorize?: false,
             query: [filter: [id: id]]
           ) do
      plain(name, "Your MSP contact")
    else
      _ -> nil
    end
  end

  defp tenant_name(tenant_id) do
    case Cloud.Accounts.get_tenant(tenant_id, authorize?: false, not_found_error?: false) do
      {:ok, %{name: name}} -> plain(name, "your organisation")
      _ -> "your organisation"
    end
  end

  defp url(path), do: base_url() <> path

  defp base_url do
    Application.get_env(:cloud, :notifications_base_url) || CloudWeb.Endpoint.url()
  end

  defp capitalise(<<first::utf8, rest::binary>>), do: String.upcase(<<first::utf8>>) <> rest
  defp capitalise(""), do: ""

  # slack treats &, < and > as control characters in text
  defp slack_escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp html_escape(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
