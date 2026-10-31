defmodule CloudWeb.RateLimit do
  @moduledoc """
  A small fixed-window counter in ETS, per node, for public pages that must
  not be hammered: the MSP request page counts every token lookup per client
  ip (threat model T6).

      case CloudWeb.RateLimit.hit({:request_lookup, ip}, 30, :timer.minutes(10)) do
        :ok -> ...
        {:error, :rate_limited} -> ...
      end

  Counters live in the window they were made in and are swept once that
  window is over. A restart forgets them, which is acceptable for a
  throttle that only slows guessing down: the tokens themselves are 256-bit.
  """

  use GenServer

  @table __MODULE__
  @sweep_ms :timer.minutes(1)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Counts one hit for `key` in the current window of `window_ms`. Returns
  `:ok` while the count is at most `limit`, then `{:error, :rate_limited}`
  until the window ends.
  """
  @spec hit(term(), pos_integer(), pos_integer()) :: :ok | {:error, :rate_limited}
  def hit(key, limit, window_ms) do
    now = System.monotonic_time(:millisecond)
    bucket = div(now, window_ms)
    expires_at = (bucket + 1) * window_ms
    counter = {key, window_ms, bucket}

    count = :ets.update_counter(@table, counter, {2, 1}, {counter, 0, expires_at})
    if count <= limit, do: :ok, else: {:error, :rate_limited}
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    schedule_sweep()
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.monotonic_time(:millisecond)
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_ms)
end
