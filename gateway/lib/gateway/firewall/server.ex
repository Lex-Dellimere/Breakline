defmodule Gateway.Firewall.Server do
  @moduledoc """
  Owns the firewall implementation state and serialises every change to it.

  Start it with `impl:` (a module implementing `Gateway.Firewall`) and `impl_opts:`
  (passed to the implementation's `init/1`), and optionally `name:` (defaults to this
  module's name).

  The server applies nothing when it starts. Its owner, the Enforcer, must apply the
  desired state after the server starts and after any restart of it. With nftables a
  restart of this process does not change the kernel ruleset, so the previous rules
  (and the resolved-address sets) keep enforcing until the next apply.

  `add_resolved` arrives as a cast so the DNS resolver never waits on the firewall; a
  failure is logged and the server carries on.
  """

  use GenServer

  require Logger

  alias Gateway.Firewall.Desired

  @doc "Returns a child spec. Takes `impl:`, `impl_opts:` and `name:`."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  @doc "Starts the server. See the moduledoc for the options."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    impl = Keyword.fetch!(opts, :impl)
    impl_opts = Keyword.get(opts, :impl_opts, [])
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, {impl, impl_opts}, name: name)
  end

  @impl true
  def init({impl, impl_opts}) do
    {:ok, state} = impl.init(impl_opts)
    {:ok, %{impl: impl, state: state, desired: nil, last_error: nil}}
  end

  @impl true
  def handle_call({:apply_desired, %Desired{} = desired}, _from, s) do
    case s.impl.apply_desired(desired, s.state) do
      {:ok, state} ->
        {:reply, :ok, %{s | state: state, desired: desired, last_error: nil}}

      {:error, reason, state} ->
        Logger.error("firewall apply failed: #{inspect(reason)}")
        {:reply, {:error, reason}, %{s | state: state, last_error: {:apply, reason}}}
    end
  end

  def handle_call(:snapshot, _from, s) do
    snapshot = %{
      impl: s.impl,
      desired: s.desired,
      last_error: s.last_error,
      state: s.impl.snapshot(s.state)
    }

    {:reply, snapshot, s}
  end

  @impl true
  def handle_cast({:add_resolved, resolved}, s) do
    case s.impl.add_resolved(resolved, s.state) do
      {:ok, state} ->
        {:noreply, %{s | state: state}}

      {:error, reason, state} ->
        Logger.warning("firewall add_resolved failed: #{inspect(reason)}")
        {:noreply, %{s | state: state, last_error: {:add_resolved, reason}}}
    end
  end
end
