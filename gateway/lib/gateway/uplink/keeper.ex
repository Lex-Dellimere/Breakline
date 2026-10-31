defmodule Gateway.Uplink.Keeper do
  @moduledoc """
  Keeps the uplink coming back, without ever spending the restart intensity of the
  supervisors above it.

  The keeper starts `Gateway.Uplink.Supervisor`, a linked `:one_for_one` supervisor
  with `Gateway.Uplink` as its only child, and traps exits. That supervisor restarts
  the uplink up to `:max_restarts` times in `:max_seconds` (10 in 60 s). When the
  uplink crashes more often than that, the supervisor gives up and exits; the keeper
  logs it at error level, counts a cool-off, and starts the supervisor again after
  `:cool_off_ms` (5 minutes). A failure to start counts the same way. The keeper
  itself does nothing that can crash, so the subtree it sits in never restarts.

  A box at a client site must always find its way back to the cloud, or no approval
  could ever reach it; enforcement does not depend on any of this.

  Options: `:uplink` (the `Gateway.Uplink` options), `:cool_off_ms`,
  `:max_restarts`, `:max_seconds` and `:name` (defaults to this module).
  """

  use GenServer

  require Logger

  @type info :: %{cool_offs: non_neg_integer(), cooling_off?: boolean()}

  @doc "Returns a child spec. See the moduledoc for options."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      shutdown: 10_000
    }
  end

  @doc "Starts the keeper. See the moduledoc for options."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Returns how many times the uplink was given up on and put in a cool-off, and
  whether it is cooling off right now.
  """
  @spec info(GenServer.server()) :: info()
  def info(server \\ __MODULE__) do
    GenServer.call(server, :info)
  catch
    :exit, _ -> %{cool_offs: 0, cooling_off?: false}
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %{
      uplink: Keyword.fetch!(opts, :uplink),
      cool_off_ms: Keyword.get(opts, :cool_off_ms, 300_000),
      max_restarts: Keyword.get(opts, :max_restarts, 10),
      max_seconds: Keyword.get(opts, :max_seconds, 60),
      sup: nil,
      timer: nil,
      cool_offs: 0
    }

    {:ok, start_uplink(state)}
  end

  @impl true
  def handle_call(:info, _from, s) do
    {:reply, %{cool_offs: s.cool_offs, cooling_off?: s.timer != nil}, s}
  end

  @impl true
  def handle_info(:restart, s), do: {:noreply, start_uplink(%{s | timer: nil})}

  def handle_info({:EXIT, pid, reason}, %{sup: pid} = s) do
    {:noreply, cool_off(%{s | sup: nil}, "the uplink supervisor exited (#{inspect(reason)})")}
  end

  def handle_info(_msg, s), do: {:noreply, s}

  @impl true
  def terminate(_reason, %{sup: pid}) when is_pid(pid) do
    Process.exit(pid, :shutdown)

    receive do
      {:EXIT, ^pid, _} -> :ok
    after
      9_000 -> Process.exit(pid, :kill)
    end
  end

  def terminate(_reason, _s), do: :ok

  defp start_uplink(s) do
    children = [{Gateway.Uplink, s.uplink}]

    opts = [
      strategy: :one_for_one,
      max_restarts: s.max_restarts,
      max_seconds: s.max_seconds,
      name: Gateway.Uplink.Supervisor
    ]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} -> %{s | sup: pid}
      other -> cool_off(s, "the uplink did not start (#{inspect(other)})")
    end
  catch
    kind, reason -> cool_off(s, "the uplink did not start (#{inspect({kind, reason})})")
  end

  defp cool_off(s, why) do
    n = s.cool_offs + 1

    Logger.error("uplink keeper: #{why}, cool-off #{n}, starting it again in #{s.cool_off_ms} ms")

    %{s | cool_offs: n, timer: Process.send_after(self(), :restart, s.cool_off_ms)}
  end
end
