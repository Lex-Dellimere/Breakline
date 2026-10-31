defmodule Gateway.Clock.System do
  @moduledoc """
  The host clock.

  `now/0` is `DateTime.utc_now/0` truncated to seconds. `synced?/0` asks systemd with
  `timedatectl show -p NTPSynchronized --value` and caches the answer for 60 seconds.
  When `timedatectl` is missing, exits non-zero or prints anything but `yes` or `no`,
  the answer is the `:assume_clock_synced` application env, which defaults to `false`:
  an unknown clock counts as unsynchronised, so the RMM channel stays locked.

  The command can be replaced with `config :gateway, :clock_command, {exe, args}`,
  which tests use to simulate a missing or failing `timedatectl`.
  """

  @behaviour Gateway.Clock

  require Logger

  @cache_key {__MODULE__, :synced}
  @cache_ms 60_000
  @default_command {"timedatectl", ["show", "-p", "NTPSynchronized", "--value"]}

  @impl true
  @spec now() :: DateTime.t()
  def now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  @impl true
  @spec synced?() :: boolean()
  def synced? do
    now = System.monotonic_time(:millisecond)

    case :persistent_term.get(@cache_key, nil) do
      {value, checked_at} when now - checked_at < @cache_ms ->
        value

      _ ->
        value = query()
        # one write a minute at most, so the global scan :persistent_term does on
        # update stays negligible
        :persistent_term.put(@cache_key, {value, now})
        value
    end
  end

  @doc "Forgets the cached answer, so the next `synced?/0` asks again. Used by tests."
  @spec reset_cache() :: :ok
  def reset_cache do
    :persistent_term.erase(@cache_key)
    :ok
  end

  @doc """
  Interprets `timedatectl` output: `{:ok, true}` for `yes`, `{:ok, false}` for `no`,
  `:error` for anything else.
  """
  @spec parse(String.t()) :: {:ok, boolean()} | :error
  def parse(output) when is_binary(output) do
    case String.trim(output) do
      "yes" -> {:ok, true}
      "no" -> {:ok, false}
      _ -> :error
    end
  end

  defp query do
    {exe, args} = Application.get_env(:gateway, :clock_command, @default_command)

    result =
      with path when is_binary(path) <- System.find_executable(exe),
           {out, 0} <- System.cmd(path, args, stderr_to_stdout: true) do
        parse(out)
      else
        _ -> :error
      end

    case result do
      {:ok, value} ->
        value

      :error ->
        fallback = Application.get_env(:gateway, :assume_clock_synced, false) == true
        Logger.warning("cannot read ntp sync status, assuming synced?=#{fallback}")
        fallback
    end
  rescue
    error ->
      Logger.warning("ntp sync status check failed: #{Exception.message(error)}")
      Application.get_env(:gateway, :assume_clock_synced, false) == true
  end
end
