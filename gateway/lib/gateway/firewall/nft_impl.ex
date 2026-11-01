defmodule Gateway.Firewall.NftImpl do
  @moduledoc """
  A `Gateway.Firewall` implementation on nftables.

  Each call builds one JSON document with `Gateway.Firewall.NftImpl.Ruleset`, writes
  it to a temporary file and runs `nft -j -f <file>`, so every change is a single
  atomic transaction on `table inet breakline`. Nothing outside that table is touched.

  Options:

    * `runner:` - a function taking the `nft` argument list and returning
      `{output, exit_status}`. Defaults to running `nft` through `System.cmd/3`. Tests
      inject a fake runner that captures the document instead.
    * `tmp_dir:` - where the temporary documents are written (defaults to
      `System.tmp_dir!/0`)
    * `ttl_floor:` and `ttl_cap:` - see `Gateway.Firewall.clamp_ttl/3`
    * `host_root:` - where `sys/class/net` and `proc/sys/net/bridge` are read for
      `host_problems/2` (defaults to `/`). Tests point it at a fake tree.

  After every successful apply the LAN interfaces are checked with `host_problems/2`.
  The ruleset is applied either way, but a problem means the gateway is not
  enforcing on that interface: it is logged at error level when it first appears and
  kept in the snapshot as `host_problems`, which the enforcer status reports.
  """

  @behaviour Gateway.Firewall

  require Logger

  alias Gateway.Firewall
  alias Gateway.Firewall.NftImpl.Ruleset

  @impl true
  def init(opts) do
    {floor, cap} = Firewall.ttl_bounds(opts)

    {:ok,
     %{
       runner: Keyword.get(opts, :runner, &default_runner/1),
       tmp_dir: Keyword.get_lazy(opts, :tmp_dir, &System.tmp_dir!/0),
       host_root: Keyword.get(opts, :host_root, "/"),
       host_problems: [],
       floor: floor,
       cap: cap,
       desired: nil,
       apply_count: 0,
       resolved_count: 0,
       last_error: nil
     }}
  end

  @impl true
  def apply_desired(desired, state) do
    case run(Ruleset.build(desired), state) do
      :ok ->
        problems = host_problems(desired.lan_interfaces, state.host_root)

        if problems != [] and problems != state.host_problems do
          Logger.error("lan interfaces not enforced: #{inspect(problems)}")
        end

        {:ok,
         %{
           state
           | desired: desired,
             apply_count: state.apply_count + 1,
             last_error: nil,
             host_problems: problems
         }}

      {:error, reason} ->
        {:error, reason, %{state | last_error: reason}}
    end
  end

  @impl true
  def add_resolved(list, state) do
    {valid, invalid} = Firewall.validate_resolved(list)

    entries =
      for {ip, ttl, _tool} <- valid, do: {ip, Firewall.clamp_ttl(ttl, state.floor, state.cap)}

    result = if entries == [], do: :ok, else: run(Ruleset.resolved(entries), state)

    case {result, invalid} do
      {:ok, []} ->
        {:ok, %{state | resolved_count: state.resolved_count + length(entries)}}

      {:ok, invalid} ->
        state = %{state | resolved_count: state.resolved_count + length(entries)}
        {:error, {:invalid_entries, invalid}, state}

      {{:error, reason}, _} ->
        {:error, reason, %{state | last_error: reason}}
    end
  end

  # one cheap list of the table, run on every enforcer evaluation
  @impl true
  def in_place?(state) do
    match?({_, 0}, state.runner.(["list", "table", Ruleset.family(), Ruleset.table()]))
  end

  @impl true
  def snapshot(state) do
    Map.take(state, [
      :desired,
      :apply_count,
      :resolved_count,
      :last_error,
      :host_problems,
      :floor,
      :cap
    ])
  end

  @typedoc "A LAN interface setup the ruleset cannot enforce, see `host_problems/2`."
  @type host_problem ::
          {:bridge_port, String.t(), String.t() | nil}
          | {:bridge_netfilter_off, String.t(), String.t()}

  @doc """
  Checks how the LAN interfaces are set up on the host, reading `sys/class/net` and
  `proc/sys/net/bridge` under `root`. It never changes anything. Problems:

    * `{:bridge_port, port, bridge}` - the interface is a port of a bridge. Bridged
      packets reach the inet hooks (through br_netfilter) with the bridge as their
      input interface, so a redirect on the port never matches and client DNS goes
      wherever the client sends it. Name the bridge instead.
    * `{:bridge_netfilter_off, bridge, sysctl}` - the interface is a bridge, and
      `net.bridge.<sysctl>` is missing (br_netfilter is not loaded) or not 1. The inet
      hooks then never see bridged packets: no DNS redirect and no drops.
  """
  @spec host_problems([String.t()], Path.t()) :: [host_problem()]
  def host_problems(lan_interfaces, root \\ "/") do
    Enum.flat_map(lan_interfaces, fn iface ->
      dev = Path.join([root, "sys/class/net", iface])

      cond do
        File.dir?(Path.join(dev, "brport")) ->
          bridge =
            case File.read_link(Path.join(dev, "master")) do
              {:ok, link} -> Path.basename(link)
              {:error, _} -> nil
            end

          [{:bridge_port, iface, bridge}]

        File.dir?(Path.join(dev, "bridge")) ->
          for sysctl <- ["bridge-nf-call-iptables", "bridge-nf-call-ip6tables"],
              read_sysctl(Path.join([root, "proc/sys/net/bridge", sysctl])) != "1",
              do: {:bridge_netfilter_off, iface, sysctl}

        true ->
          []
      end
    end)
  end

  defp read_sysctl(path) do
    case File.read(path) do
      {:ok, text} -> String.trim(text)
      {:error, _} -> nil
    end
  end

  defp run(document, state) do
    path = Path.join(state.tmp_dir, "breakline-nft-#{System.unique_integer([:positive])}.json")

    case File.write(path, JSON.encode!(document)) do
      :ok ->
        try do
          case state.runner.(["-j", "-f", path]) do
            {_output, 0} -> :ok
            {output, status} -> {:error, {:nft_failed, status, output}}
          end
        after
          File.rm(path)
        end

      {:error, reason} ->
        {:error, {:tmp_write_failed, path, reason}}
    end
  end

  defp default_runner(args) do
    System.cmd("nft", args, stderr_to_stdout: true)
  rescue
    e in ErlangError -> {"nft could not be run: #{Exception.message(e)}", 127}
  end
end
