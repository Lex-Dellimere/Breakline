defmodule Gateway.Events do
  @moduledoc """
  A bounded in-memory ring buffer of gateway events: DNS blocks and would-blocks,
  enforcer state changes, applied and rejected policies.

  `record/1` is a cast, so a caller (a DNS query task, the Enforcer) never waits on
  it, and it is a no-op when the buffer is not running. When the buffer is full the
  oldest event is dropped and counted. The phase 3 uplink will `drain/1` events
  oldest first and send them to the cloud; `recent/1` is for status and tests.

  Events are not persisted: the audit chain is the durable record, this is the
  telemetry stream.

  Options: `:capacity` (default 10_000) and `:name` (defaults to this module).
  """

  use GenServer

  @default_capacity 10_000

  @typedoc "An event map; DNS events carry `:type`, `:qname`, `:match`, `:at` and more."
  @type event :: map()

  @doc "Returns a child spec. See the moduledoc for options."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  @doc "Starts the buffer. See the moduledoc for options."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    capacity = Keyword.get(opts, :capacity, @default_capacity)

    unless is_integer(capacity) and capacity > 0 do
      raise ArgumentError, "capacity must be a positive integer, got: #{inspect(capacity)}"
    end

    GenServer.start_link(__MODULE__, capacity, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Records an event without waiting. Never fails, even when the buffer is down."
  @spec record(event(), GenServer.server()) :: :ok
  def record(event, server \\ __MODULE__) when is_map(event) do
    GenServer.cast(server, {:record, event})
  end

  @doc "Returns up to `n` of the newest events, oldest first, without removing them."
  @spec recent(non_neg_integer(), GenServer.server()) :: [event()]
  def recent(n \\ 100, server \\ __MODULE__) when is_integer(n) and n >= 0 do
    GenServer.call(server, {:recent, n})
  end

  @doc "Removes and returns up to `n` of the oldest events, oldest first."
  @spec drain(non_neg_integer(), GenServer.server()) :: [event()]
  def drain(n \\ 1000, server \\ __MODULE__) when is_integer(n) and n >= 0 do
    GenServer.call(server, {:drain, n})
  end

  @doc "Returns the buffer size, capacity and the number of events dropped as overflow."
  @spec stats(GenServer.server()) :: %{
          size: non_neg_integer(),
          capacity: pos_integer(),
          dropped: non_neg_integer()
        }
  def stats(server \\ __MODULE__), do: GenServer.call(server, :stats)

  @impl true
  def init(capacity) do
    {:ok, %{queue: :queue.new(), size: 0, capacity: capacity, dropped: 0}}
  end

  @impl true
  def handle_cast({:record, event}, %{size: size, capacity: cap} = s) when size >= cap do
    {_, queue} = :queue.out(s.queue)
    {:noreply, %{s | queue: :queue.in(event, queue), dropped: s.dropped + 1}}
  end

  def handle_cast({:record, event}, s) do
    {:noreply, %{s | queue: :queue.in(event, s.queue), size: s.size + 1}}
  end

  @impl true
  def handle_call({:recent, n}, _from, s) do
    list = :queue.to_list(s.queue)
    {:reply, Enum.drop(list, max(s.size - n, 0)), s}
  end

  def handle_call({:drain, n}, _from, s) do
    take = min(n, s.size)
    {taken, rest} = :queue.split(take, s.queue)
    {:reply, :queue.to_list(taken), %{s | queue: rest, size: s.size - take}}
  end

  def handle_call(:stats, _from, s) do
    {:reply, %{size: s.size, capacity: s.capacity, dropped: s.dropped}, s}
  end
end
