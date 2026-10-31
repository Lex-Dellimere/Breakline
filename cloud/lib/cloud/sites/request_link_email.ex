defmodule Cloud.Sites.RequestLinkEmail do
  @moduledoc """
  The email that hands an MSP contact their request link: plain text and
  HTML, carrying the site's name, the expiry and the URL. The URL is the only
  secret in it; it can only request a window, never approve one.
  """

  import Swoosh.Email

  alias Cloud.Sites.RequestLinks

  @from {"Breakline", "noreply@example.com"}

  @doc "Builds the email for a contact, a site, a raw token and the link's expiry."
  @spec build(map(), map(), String.t(), DateTime.t()) :: Swoosh.Email.t()
  def build(contact, site, token, expires_at) do
    url = RequestLinks.request_url(token)
    expires = Calendar.strftime(expires_at, "%d %b %Y")

    new()
    |> from(@from)
    |> to({contact.name, to_string(contact.email)})
    |> subject("Request a maintenance window for #{site.name}")
    |> text_body("""
    Hello #{contact.name},

    Use this link to request a remote access window for #{site.name}:

    #{url}

    The link can only ask for a window. Your client approves each request
    before anything opens. It works until #{expires}. Do not forward it.
    """)
    |> html_body("""
    <p>Hello #{html(contact.name)},</p>
    <p>Use this link to request a remote access window for #{html(site.name)}:</p>
    <p><a href="#{html(url)}">#{html(url)}</a></p>
    <p>The link can only ask for a window. Your client approves each request before
    anything opens. It works until #{expires}. Do not forward it.</p>
    """)
  end

  @doc "Builds and sends the email. Returns `:ok` or `{:error, reason}`."
  @spec deliver(map(), map(), String.t(), DateTime.t()) :: :ok | {:error, term()}
  def deliver(contact, site, token, expires_at) do
    case contact |> build(site, token, expires_at) |> Cloud.Mailer.deliver() do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp html(text),
    do: text |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
