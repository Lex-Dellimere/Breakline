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
  """

  @behaviour Gateway.Firewall

  alias Gateway.Firewall
  alias Gateway.Firewall.NftImpl.Ruleset

  @impl true
  def init(opts) do
    {floor, cap} = Firewall.ttl_bounds(opts)

    {:ok,
     %{
       runner: Keyword.get(opts, :runner, &default_runner/1),
       tmp_dir: Keyword.get_lazy(opts, :tmp_dir, &System.tmp_dir!/0),
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
        {:ok, %{state | desired: desired, apply_count: state.apply_count + 1, last_error: nil}}

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

  @impl true
  def snapshot(state) do
    Map.take(state, [:desired, :apply_count, :resolved_count, :last_error, :floor, :cap])
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
