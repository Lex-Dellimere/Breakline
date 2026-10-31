defmodule Gateway.Clock.Fake do
  @moduledoc """
  A settable clock for tests: an Agent registered under this module's name.

  Start it with `start_link(now: ~U[...], synced?: true)`; both are optional (now
  defaults to the real time and synced to true). `set_now/1`, `advance/1` and
  `set_synced/1` move it. Times are kept in UTC, truncated to whole seconds.
  """

  @behaviour Gateway.Clock

  use Agent

  @doc "Starts the fake clock. Takes `now:` and `synced?:`."
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    now = opts |> Keyword.get_lazy(:now, &DateTime.utc_now/0) |> normalize()
    synced? = Keyword.get(opts, :synced?, true)
    Agent.start_link(fn -> %{now: now, synced?: synced?} end, name: __MODULE__)
  end

  @impl true
  @spec now() :: DateTime.t()
  def now, do: Agent.get(__MODULE__, & &1.now)

  @impl true
  @spec synced?() :: boolean()
  def synced?, do: Agent.get(__MODULE__, & &1.synced?)

  @doc "Sets the current time."
  @spec set_now(DateTime.t()) :: :ok
  def set_now(%DateTime{} = now), do: Agent.update(__MODULE__, &%{&1 | now: normalize(now)})

  @doc "Moves the clock forward (or back, with a negative value) by `seconds`."
  @spec advance(integer()) :: :ok
  def advance(seconds) when is_integer(seconds) do
    Agent.update(__MODULE__, &%{&1 | now: DateTime.add(&1.now, seconds)})
  end

  @doc "Sets whether the clock reports itself as synchronised."
  @spec set_synced(boolean()) :: :ok
  def set_synced(synced?) when is_boolean(synced?) do
    Agent.update(__MODULE__, &%{&1 | synced?: synced?})
  end

  defp normalize(dt), do: dt |> DateTime.shift_zone!("Etc/UTC") |> DateTime.truncate(:second)
end
