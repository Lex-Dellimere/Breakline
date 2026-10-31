defmodule Gateway.Firewall.NftDockerTest do
  # runs the golden nft documents through real nftables inside a throwaway debian
  # container with its own network namespace. never touches the host's networking:
  # no --network host, no --privileged, only NET_ADMIN inside the container.
  # excluded by default; run with `mix test --only nft_docker` (needs docker and
  # network access for apt-get inside the container).
  use ExUnit.Case, async: false

  alias Gateway.Firewall.NftImpl.Ruleset

  @moduletag :nft_docker
  @moduletag timeout: 900_000

  @fixtures Path.expand("../../fixtures/nft", __DIR__)
  @image "debian:trixie-slim"
  @rulesets ["enforce_locked", "enforce_open", "monitor_locked", "empty_lists", "ipv6"]

  defp docker(script, extra_mounts \\ []) do
    mounts =
      Enum.flat_map([{@fixtures, "/rules"} | extra_mounts], fn {host, guest} ->
        ["-v", "#{host}:#{guest}:ro"]
      end)

    setup = "apt-get update -qq && apt-get install -y -qq nftables >/dev/null 2>&1"

    args =
      ["run", "--rm", "--cap-add", "NET_ADMIN"] ++
        mounts ++ [@image, "sh", "-c", setup <> " && " <> script]

    System.cmd("docker", args, stderr_to_stdout: false)
  end

  # splits stdout on "=== name" marker lines into %{name => decoded json}.
  defp sections(stdout) do
    stdout
    |> String.split(~r/^=== /m, trim: true)
    |> Map.new(fn chunk ->
      [name, body] = String.split(chunk, "\n", parts: 2)
      {name, JSON.decode!(body)}
    end)
  end

  defp list(name, what \\ "table inet breakline"), do: "echo '=== #{name}' && nft -j list #{what}"

  defp objects(listing, kind), do: for(%{^kind => o} <- listing["nftables"], do: o)

  defp elems(listing, set) do
    [%{"name" => ^set} = s] = objects(listing, "set") |> Enum.filter(&(&1["name"] == set))
    Map.get(s, "elem", [])
  end

  defp rule_count(listing, chain),
    do: Enum.count(objects(listing, "rule"), &(&1["chain"] == chain))

  defp expected_rules(name) do
    doc = JSON.decode!(File.read!(Path.join(@fixtures, name <> ".json")))

    for %{"add" => %{"rule" => %{"chain" => c}}} <- doc["nftables"], reduce: %{} do
      acc -> Map.update(acc, c, 1, &(&1 + 1))
    end
  end

  setup_all do
    unless System.find_executable("docker"), do: raise("docker is required for nft_docker tests")
    :ok
  end

  test "every golden ruleset loads into real nft and lists back as expected" do
    results =
      @rulesets
      |> Task.async_stream(
        fn name ->
          {out, status} = docker("nft -j -f /rules/#{name}.json && " <> list(name))
          {name, status, out}
        end,
        timeout: 600_000,
        max_concurrency: 5
      )
      |> Enum.map(fn {:ok, r} -> r end)

    for {name, status, out} <- results do
      assert status == 0, "#{name}: nft failed (exit #{status}):\n#{out}"
      listing = sections(out) |> Map.fetch!(name)
      expected = expected_rules(name)
      assert rule_count(listing, "prerouting") == expected["prerouting"], name
      assert rule_count(listing, "forward") == expected["forward"], name

      names = objects(listing, "set") |> Enum.map(& &1["name"]) |> Enum.sort()
      assert names == ~w(block4 block6 doh4 doh6 rmm4 rmm6), name

      chains = Map.new(objects(listing, "chain"), &{&1["name"], &1})
      assert %{"type" => "nat", "hook" => "prerouting", "prio" => -100} = chains["prerouting"]

      assert %{"type" => "filter", "hook" => "forward", "prio" => -10, "policy" => "accept"} =
               chains["forward"]
    end
  end

  test "resolved elements survive re-applies and lock changes, and a re-add resets the timeout" do
    extra =
      Path.join(System.tmp_dir!(), "breakline-nft-docker-#{System.unique_integer([:positive])}")

    File.mkdir_p!(extra)
    on_exit(fn -> File.rm_rf!(extra) end)

    # a shorter re-add of an address from add_resolved.json, to observe kernel semantics.
    File.write!(
      Path.join(extra, "readd_short.json"),
      JSON.encode!(Ruleset.resolved([{{203, 0, 113, 11}, 3_600}]))
    )

    script =
      Enum.join(
        [
          # add_resolved before any apply works on its own.
          "nft -j -f /rules/add_resolved.json",
          list("before_apply", "set inet breakline rmm4"),
          "nft -j -f /rules/enforce_locked.json",
          "nft -j -f /rules/enforce_locked.json",
          list("locked_twice"),
          "nft -j -f /rules/enforce_open.json",
          list("open"),
          "nft -j -f /rules/monitor_locked.json",
          "nft -j -f /rules/enforce_locked.json",
          "nft -j -f /rules/add_resolved.json",
          list("relocked"),
          "nft -j -f /extra/readd_short.json",
          list("readd_short", "set inet breakline rmm4")
        ],
        " && "
      )

    {out, status} = docker(script, [{extra, "/extra"}])
    assert status == 0, "nft sequence failed (exit #{status}):\n#{out}"
    s = sections(out)

    expected = expected_rules("enforce_locked")
    resolved4 = ["203.0.113.10", "203.0.113.11"]

    vals = fn listing, set ->
      listing |> elems(set) |> Enum.map(fn %{"elem" => %{"val" => v}} -> v end) |> Enum.sort()
    end

    assert vals.(s["before_apply"], "rmm4") == resolved4

    for stage <- ["locked_twice", "open", "relocked"] do
      assert vals.(s[stage], "rmm4") == resolved4, stage
      assert vals.(s[stage], "rmm6") == ["2001:db8::10"], stage
    end

    # applying twice does not duplicate rules or set elements.
    assert rule_count(s["locked_twice"], "forward") == expected["forward"]
    assert rule_count(s["relocked"], "forward") == expected["forward"]
    assert length(elems(s["locked_twice"], "block4")) == 2
    assert rule_count(s["open"], "forward") == expected_rules("enforce_open")["forward"]

    timeout = fn listing, ip ->
      Enum.find_value(elems(listing, "rmm4"), fn %{"elem" => e} ->
        e["val"] == ip && e["timeout"]
      end)
    end

    assert timeout.(s["relocked"], "203.0.113.11") == 7_200
    # on this kernel a re-add replaces the timeout, also when it is shorter.
    assert timeout.(s["readd_short"], "203.0.113.11") == 3_600
  end
end
