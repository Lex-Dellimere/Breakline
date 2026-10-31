defmodule Cloud.Sites.RequestLinks do
  @moduledoc """
  Tokens and lookups for `Cloud.Sites.RequestLink`, the MSP contact's magic
  link (threat model T6).

  A token is 32 bytes from `:crypto.strong_rand_bytes/1`, base64url encoded
  without padding into the URL. Only `hash_token/1` of it, the lowercase hex
  sha256 of the 32 bytes, is stored.

  `lookup/1` is the trusted step of the public request page: it finds the
  link by the hash of the token in the URL. An unknown, malformed, expired
  or revoked token all give the same `{:error, :invalid}` after the same
  single query, so the page can never tell anyone why a link failed or
  whether a site exists.
  """

  use CloudWeb, :verified_routes

  alias Cloud.Sites
  alias Cloud.Sites.RequestLink

  @ttl_days 14
  @token_bytes 32

  @doc "How long a new link is valid, in days."
  def ttl_days, do: @ttl_days

  @doc "A new raw token and its hash: `{token, token_hash}`."
  @spec new_token() :: {String.t(), String.t()}
  def new_token do
    raw = :crypto.strong_rand_bytes(@token_bytes)
    {Base.url_encode64(raw, padding: false), sha256(raw)}
  end

  @doc """
  The stored hash for a token from a URL. A string that is not a well-formed
  token still hashes (to a value no link can have), so every lookup does the
  same work.
  """
  @spec hash_token(String.t()) :: String.t()
  def hash_token(token) when is_binary(token) do
    case Base.url_decode64(token, padding: false) do
      {:ok, <<_::binary-size(@token_bytes)>> = raw} -> sha256(raw)
      _ -> sha256("malformed:" <> token)
    end
  end

  @doc """
  Trusted: the usable link for a raw token, with its site and contact
  loaded, or `{:error, :invalid}` for anything else.
  """
  @spec lookup(String.t()) :: {:ok, RequestLink.t()} | {:error, :invalid}
  def lookup(token) when is_binary(token) do
    case Sites.get_request_link_by_token_hash(hash_token(token),
           authorize?: false,
           not_found_error?: false,
           load: [:site, :msp_contact]
         ) do
      {:ok, %RequestLink{} = link} ->
        if usable?(link), do: {:ok, link}, else: {:error, :invalid}

      _ ->
        {:error, :invalid}
    end
  end

  def lookup(_token), do: {:error, :invalid}

  @doc "Whether a link is neither revoked nor expired at `now`."
  @spec usable?(RequestLink.t(), DateTime.t()) :: boolean()
  def usable?(%RequestLink{} = link, now \\ DateTime.utc_now()) do
    is_nil(link.revoked_at) and DateTime.compare(link.expires_at, now) == :gt
  end

  @doc "The status of a link for display: `:active`, `:expired` or `:revoked`."
  @spec status(RequestLink.t(), DateTime.t()) :: :active | :expired | :revoked
  def status(%RequestLink{} = link, now \\ DateTime.utc_now()) do
    cond do
      link.revoked_at -> :revoked
      usable?(link, now) -> :active
      true -> :expired
    end
  end

  @doc "The full URL of the request page for a raw token."
  @spec request_url(String.t()) :: String.t()
  def request_url(token) when is_binary(token), do: url(~p"/request/#{token}")

  @doc """
  Requests a one-off window through a link, with the link as the actor of
  `Cloud.Sites.Window`'s `:request` action. `params` may hold `starts_at`,
  `ends_at` (local naive datetimes in the site's zone) and `reason`;
  anything else is ignored, and the site, contact and kind come from the
  link.
  """
  @spec request_window(RequestLink.t(), map()) :: {:ok, Sites.Window.t()} | {:error, term()}
  def request_window(%RequestLink{} = link, params) when is_map(params) do
    params
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> Map.take(["starts_at", "ends_at", "reason"])
    |> Sites.request_window(actor: link, tenant: link.tenant_id)
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
