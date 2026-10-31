defmodule Cloud.Notifications.Webhook do
  @moduledoc """
  Posts a json payload to a Slack or Teams webhook with Req.

  The URL is checked again with `Cloud.Notifications.Target.validate/2`
  right before the request, so a target that slipped past validation is
  never contacted. Redirects are not followed, Req's own retries are off
  (the Oban worker retries), timeouts are short and the response body is
  ignored: only the status counts. Errors never contain the URL.

  Extra Req options come from `config :cloud, Cloud.Notifications.Webhook,
  req_options: [...]` (tests point it at a `Req.Test` stub).
  """

  alias Cloud.Notifications.Target

  @type error :: {:http_status, pos_integer()} | {:transport, String.t()} | :invalid_target

  @doc "Posts `payload` to `url`, a webhook of `kind`."
  @spec post(:slack | :teams, String.t(), map()) :: :ok | {:error, error()}
  def post(kind, url, payload) when kind in [:slack, :teams] do
    case Target.validate(kind, url) do
      {:ok, url} -> request(url, payload)
      {:error, _message} -> {:error, :invalid_target}
    end
  end

  defp request(url, payload) do
    options =
      [
        url: url,
        method: :post,
        json: payload,
        headers: [{"user-agent", "breakline-cloud notifications"}],
        redirect: false,
        retry: false,
        decode_body: false,
        connect_options: [timeout: 5_000],
        receive_timeout: 10_000
      ]
      |> Keyword.merge(config_options())

    case Req.request(options) do
      {:ok, %Req.Response{status: status}} when status in 200..299 -> :ok
      {:ok, %Req.Response{status: status}} -> {:error, {:http_status, status}}
      {:error, %{reason: reason}} -> {:error, {:transport, transport_reason(reason)}}
      {:error, _exception} -> {:error, {:transport, "request failed"}}
    end
  end

  # only an atom reason, never the exception message, which could name the url
  defp transport_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp transport_reason(_reason), do: "request failed"

  defp config_options do
    :cloud |> Application.get_env(__MODULE__, []) |> Keyword.get(:req_options, [])
  end
end
