defmodule Cloud.Advisories.HTTP do
  @moduledoc """
  Conditional GETs for the threat feeds, with Req.

  The feed's stored `etag` and `last_modified` go out as `if-none-match` and
  `if-modified-since`, so an unchanged feed answers 304 and is not parsed.
  Requests use HTTP/1.1 only (cyber.gov.au fails over HTTP/2) and the raw
  body is returned undecoded.

  Extra Req options come from `config :cloud, Cloud.Advisories.HTTP,
  req_options: [...]` (tests point it at a `Req.Test` stub) and from the
  `:req_options` option of `get/3`, which wins.
  """

  @user_agent "breakline-cloud advisory poller"

  @type result ::
          {:ok, :not_modified}
          | {:ok, %{body: binary(), etag: String.t() | nil, last_modified: String.t() | nil}}
          | {:error, term()}

  @doc """
  Fetches `url`. `validators` is a map with the optional `:etag` and
  `:last_modified` of the previous response.
  """
  @spec get(String.t(), map(), keyword()) :: result()
  def get(url, validators, opts \\ []) do
    headers =
      [{"user-agent", @user_agent}] ++
        header("if-none-match", validators[:etag]) ++
        header("if-modified-since", validators[:last_modified])

    options =
      [
        url: url,
        method: :get,
        headers: headers,
        decode_body: false,
        compressed: true,
        receive_timeout: 30_000,
        retry: :transient,
        max_retries: 2,
        connect_options: [protocols: [:http1]]
      ]
      |> Keyword.merge(config_options())
      |> Keyword.merge(Keyword.get(opts, :req_options, []))

    case Req.request(options) do
      {:ok, %Req.Response{status: 304}} ->
        {:ok, :not_modified}

      {:ok, %Req.Response{status: 200, body: body} = response} when is_binary(body) ->
        {:ok,
         %{
           body: body,
           etag: first_header(response, "etag"),
           last_modified: first_header(response, "last-modified")
         }}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_status, status}}

      {:error, exception} ->
        {:error, {:transport, Exception.message(exception)}}
    end
  end

  defp header(_name, nil), do: []
  defp header(name, value), do: [{name, value}]

  defp first_header(response, name) do
    case Req.Response.get_header(response, name) do
      [value | _] -> value
      [] -> nil
    end
  end

  defp config_options do
    :cloud |> Application.get_env(__MODULE__, []) |> Keyword.get(:req_options, [])
  end
end
