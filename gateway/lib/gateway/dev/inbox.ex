defmodule Gateway.Dev.Inbox do
  @moduledoc """
  A dev-only stand-in for the phase 3 uplink: polls a directory for signed command
  files and submits them to `Gateway.Enforcer`.

  Every `:interval_ms` (default 2000) it submits each `*.json` file in `:dir`, oldest
  name first, and moves it to `processed/` when accepted or `rejected/` otherwise,
  logging the reason. Write files atomically (for example to `x.json.tmp`, then rename)
  so a half-written file is never picked up; `mix gateway.dev.sign` does.

  It is only started when `config :gateway, :inbox_dir` is set, which only the dev
  config does.
  """

  use GenServer

  require Logger

  @doc "Returns a child spec. Takes `dir:`, `interval_ms:` and `enforcer:`."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  @doc "Starts the poller."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Processes the inbox now and returns `[{file, :ok | {:error, reason}}]`."
  @spec poll(GenServer.server()) :: [{String.t(), :ok | {:error, term()}}]
  def poll(server \\ __MODULE__), do: GenServer.call(server, :poll, 30_000)

  @impl true
  def init(opts) do
    dir = opts |> Keyword.fetch!(:dir) |> Path.expand()
    Enum.each(["processed", "rejected"], &File.mkdir_p!(Path.join(dir, &1)))
    Logger.info("dev inbox watching #{dir}")

    state = %{
      dir: dir,
      interval: Keyword.get(opts, :interval_ms, 2000),
      enforcer: Keyword.get(opts, :enforcer, Gateway.Enforcer)
    }

    {:ok, schedule(state)}
  end

  @impl true
  def handle_call(:poll, _from, s), do: {:reply, process(s), s}

  @impl true
  def handle_info(:poll, s) do
    process(s)
    {:noreply, schedule(s)}
  end

  defp schedule(s) do
    Process.send_after(self(), :poll, s.interval)
    s
  end

  defp process(s) do
    s.dir
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(fn path ->
      result = submit(path, s.enforcer)
      name = Path.basename(path)

      sub =
        case result do
          :ok ->
            Logger.info("inbox: applied #{name}")
            "processed"

          {:error, reason} ->
            Logger.warning("inbox: rejected #{name}: #{inspect(reason)}")
            "rejected"
        end

      File.rename(path, Path.join([s.dir, sub, name]))
      {name, result}
    end)
  end

  defp submit(path, enforcer) do
    case File.read(path) do
      {:ok, bytes} -> Gateway.Enforcer.submit(bytes, enforcer)
      {:error, reason} -> {:error, {:read_failed, reason}}
    end
  catch
    :exit, reason -> {:error, {:enforcer_unavailable, reason}}
  end
end
