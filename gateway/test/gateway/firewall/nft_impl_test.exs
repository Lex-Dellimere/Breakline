defmodule Gateway.Firewall.NftImplTest do
  # golden tests for the nft json documents. regenerate the fixtures with
  # `UPDATE_NFT_FIXTURES=1 mix test test/gateway/firewall/nft_impl_test.exs` and
  # review the diff; `mix test --only nft_docker` checks them against real nft.
  use ExUnit.Case, async: true

  alias Gateway.Firewall.{Desired, NftImpl}
  alias Gateway.Firewall.NftImpl.Ruleset

  @fixtures Path.expand("../../fixtures/nft", __DIR__)

  defp desired(extra) do
    base = [
      locked?: true,
      mode: :enforce,
      lan_interfaces: ["eth1"],
      dns_port: 5353,
      block_cidrs: ["192.0.2.0/24", "198.51.100.7", "2001:db8:42::/48"],
      exclusive_ports: Breakline.Catalog.exclusive_ports(Breakline.Catalog.ids()),
      doh_ips: ["1.1.1.1", "8.8.8.8", "2606:4700:4700::1111"]
    ]

    {:ok, d} = Desired.new(Keyword.merge(base, extra))
    d
  end

  @resolved [
    {{203, 0, 113, 10}, 30, "anydesk"},
    {{203, 0, 113, 11}, 7_200, "anydesk"},
    {{0x2001, 0xDB8, 0, 0, 0, 0, 0, 0x10}, 999_999, "teamviewer"}
  ]

  defp cases do
    %{
      "enforce_locked" => desired([]),
      "enforce_open" => desired(locked?: false),
      "monitor_locked" => desired(mode: :monitor),
      "empty_lists" => desired(block_cidrs: [], exclusive_ports: [], doh_ips: []),
      "ipv6" =>
        desired(
          lan_interfaces: ["eth1", "wlan0"],
          block_cidrs: ["2001:db8:42::/48", "2001:db8:43::1", "fd00::/8"],
          exclusive_ports: [%{port: 7070, proto: :tcp}],
          doh_ips: ["2606:4700:4700::1111", "2001:4860:4860::8888"]
        )
    }
  end

  # a fake runner that sends the decoded document to the test process.
  defp capture_runner(status \\ 0) do
    test = self()

    fn ["-j", "-f", path] ->
      send(test, {:nft, JSON.decode!(File.read!(path))})
      {"output", status}
    end
  end

  defp init(opts \\ []) do
    {:ok, state} = NftImpl.init(Keyword.merge([runner: capture_runner()], opts))
    state
  end

  defp golden(name, doc) do
    path = Path.join(@fixtures, name <> ".json")
    text = pretty(doc) <> "\n"

    if System.get_env("UPDATE_NFT_FIXTURES") do
      File.mkdir_p!(@fixtures)
      File.write!(path, text)
    end

    assert File.read!(path) == text, "#{name} differs from #{path}"
    assert JSON.decode!(File.read!(path)) == doc
  end

  describe "golden documents" do
    for name <- ["enforce_locked", "enforce_open", "monitor_locked", "empty_lists", "ipv6"] do
      test name do
        name = unquote(name)
        d = Map.fetch!(cases(), name)
        {:ok, _} = NftImpl.apply_desired(d, init())
        assert_received {:nft, doc}
        assert doc == json_roundtrip(Ruleset.build(d))
        golden(name, doc)
      end
    end

    test "add_resolved" do
      {:ok, state} = NftImpl.add_resolved(@resolved, init())
      assert_received {:nft, doc}
      golden("add_resolved", doc)
      assert state.resolved_count == 3

      timeouts =
        for %{"add" => %{"element" => %{"elem" => elems}}} <- doc["nftables"],
            %{"elem" => %{"val" => v, "timeout" => t}} <- elems,
            do: {v, t}

      assert timeouts == [
               {"203.0.113.10", 3_600},
               {"203.0.113.11", 7_200},
               {"2001:db8::10", 86_400}
             ]
    end
  end

  describe "ruleset" do
    test "is deterministic byte for byte" do
      d = desired([])
      assert JSON.encode!(Ruleset.build(d)) == JSON.encode!(Ruleset.build(d))
      {:ok, shuffled} = Desired.new(Map.from_struct(d) |> Map.take(keys()) |> shuffle_lists())
      assert JSON.encode!(Ruleset.build(shuffled)) == JSON.encode!(Ruleset.build(d))
    end

    test "only ever touches table inet breakline" do
      for {_, d} <- cases(),
          doc <- [Ruleset.build(d), Ruleset.resolved([{{192, 0, 2, 1}, 60}])] do
        for cmd <- doc["nftables"], {_verb, obj} <- cmd, {kind, body} <- obj do
          assert body["family"] == "inet"

          if kind == "table",
            do: assert(body["name"] == "breakline"),
            else: assert(body["table"] == "breakline")
        end
      end
    end

    test "resolved documents use the longest timeout for duplicates and skip empty families" do
      doc = Ruleset.resolved([{{192, 0, 2, 1}, 60}, {{192, 0, 2, 1}, 90}])
      assert [%{"add" => %{"element" => %{"name" => "rmm4", "elem" => [elem]}}}] = elements(doc)
      assert elem == %{"elem" => %{"val" => "192.0.2.1", "timeout" => 90}}
    end
  end

  describe "properties" do
    test "an apply never flushes, deletes or refills the resolved sets" do
      for d <- random_desired(300) do
        for cmd <- Ruleset.build(d)["nftables"] do
          refute match?(%{"flush" => %{"set" => %{"name" => "rmm" <> _}}}, cmd)
          refute match?(%{"delete" => _}, cmd)
          refute match?(%{"flush" => %{"table" => _}}, cmd)
          refute match?(%{"flush" => %{"ruleset" => _}}, cmd)
          refute match?(%{"add" => %{"element" => %{"name" => "rmm" <> _}}}, cmd)
          refute match?(%{"add" => %{"set" => %{"name" => "rmm" <> _, "elem" => _}}}, cmd)
        end
      end
    end

    test "an open lock never emits rmm, block or exclusive port rules" do
      for d <- random_desired(300) do
        rules = forward_rules(Ruleset.build(%{d | locked?: false}))
        text = JSON.encode!(rules)
        refute text =~ "@rmm"
        refute text =~ "@block"
        assert length(rules) == 6
      end
    end

    test "a locked state drops every exclusive port and both address sets" do
      for d <- random_desired(300), d.locked? do
        rules = forward_rules(Ruleset.build(d))
        text = JSON.encode!(rules)

        for set <- ["@rmm4", "@rmm6", "@block4", "@block6", "@doh4", "@doh6"],
            do: assert(text =~ set)

        dropped =
          for rule <- rules,
              %{
                "match" => %{
                  "left" => %{"payload" => %{"protocol" => proto, "field" => "dport"}},
                  "right" => %{"set" => ps}
                }
              } <- rule,
              p <- ps,
              do: %{port: p, proto: String.to_atom(proto)}

        assert Enum.sort_by(dropped, &{&1.port, &1.proto}) == d.exclusive_ports
      end
    end

    test "every forward rule counts, enforce drops and monitor only logs" do
      for d <- random_desired(300), rule <- forward_rules(Ruleset.build(d)) do
        tail = Enum.take(rule, -2)

        case d.mode do
          :enforce ->
            assert tail == [%{"counter" => nil}, %{"drop" => nil}]

          :monitor ->
            assert [%{"counter" => nil}, %{"log" => %{"prefix" => "breakline would-block " <> _}}] =
                     tail

            refute Enum.any?(rule, &Map.has_key?(&1, "drop"))
        end
      end
    end

    test "the dns redirect is always present" do
      for d <- random_desired(100) do
        redirects =
          for %{"add" => %{"rule" => %{"chain" => "prerouting", "expr" => expr}}} <-
                Ruleset.build(d)["nftables"],
              %{"redirect" => %{"port" => port}} <- expr,
              do: port

        assert redirects == [d.dns_port, d.dns_port]
      end
    end
  end

  describe "execution" do
    test "runs nft -j -f with a temp file and removes it" do
      test = self()

      dir =
        Path.join(System.tmp_dir!(), "breakline-nft-test-#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      runner = fn args ->
        send(test, {:args, args})
        {"", 0}
      end

      {:ok, state} = NftImpl.apply_desired(desired([]), init(runner: runner, tmp_dir: dir))
      assert_received {:args, ["-j", "-f", path]}
      assert Path.dirname(path) == dir
      refute File.exists?(path)
      assert %{apply_count: 1, desired: %Desired{}, last_error: nil} = NftImpl.snapshot(state)
    end

    test "a failing nft run is an error and keeps the previous desired state" do
      {:ok, state} = NftImpl.apply_desired(desired([]), init())
      state = %{state | runner: capture_runner(1)}

      assert {:error, {:nft_failed, 1, "output"}, state} =
               NftImpl.apply_desired(desired(locked?: false), state)

      assert %{desired: %Desired{locked?: true}, apply_count: 1} = NftImpl.snapshot(state)
      assert {:error, {:nft_failed, 1, _}, _} = NftImpl.add_resolved(@resolved, state)
    end

    test "an unwritable tmp dir is an error, not a crash" do
      state = init(tmp_dir: "/nonexistent/breakline")

      assert {:error, {:tmp_write_failed, _, :enoent}, _} =
               NftImpl.apply_desired(desired([]), state)
    end

    test "add_resolved skips nft when nothing is valid and reports invalid entries" do
      assert {:error, {:invalid_entries, [:junk]}, _} = NftImpl.add_resolved([:junk], init())
      refute_received {:nft, _}
      assert {:ok, _} = NftImpl.add_resolved([], init())
      refute_received {:nft, _}
    end

    test "the default runner reports a missing nft binary instead of raising" do
      if System.find_executable("nft") do
        # never run nft on the host.
        :ok
      else
        {:ok, state} = NftImpl.init([])
        assert {:error, {:nft_failed, 127, _}, _} = NftImpl.apply_desired(desired([]), state)
      end
    end
  end

  # helpers

  defp keys,
    do: [:locked?, :mode, :lan_interfaces, :dns_port, :block_cidrs, :exclusive_ports, :doh_ips]

  defp shuffle_lists(map) do
    Map.new(map, fn
      {k, v} when is_list(v) -> {k, Enum.shuffle(v ++ v)}
      kv -> kv
    end)
  end

  defp json_roundtrip(doc), do: doc |> JSON.encode!() |> JSON.decode!()

  defp elements(doc), do: for(%{"add" => %{"element" => _}} = c <- doc["nftables"], do: c)

  defp forward_rules(doc) do
    for %{"add" => %{"rule" => %{"chain" => "forward", "expr" => expr}}} <- doc["nftables"],
        do: expr
  end

  # seeded so failures reproduce; prints nothing unless an assertion fails.
  defp random_desired(n) do
    :rand.seed(:exsss, {1, 2, 3})

    for _ <- 1..n do
      {:ok, d} =
        Desired.new(
          locked?: :rand.uniform(2) == 1,
          mode: Enum.random([:enforce, :monitor]),
          lan_interfaces: Enum.take_random(["eth1", "eth2", "br0", "wlan0"], :rand.uniform(4)),
          dns_port: :rand.uniform(65_535),
          block_cidrs: for(_ <- 0..:rand.uniform(6)//1, do: random_cidr()) |> Enum.drop(1),
          exclusive_ports:
            for(
              _ <- 0..:rand.uniform(6)//1,
              do: %{port: :rand.uniform(65_535), proto: Enum.random([:tcp, :udp])}
            )
            |> Enum.drop(1),
          doh_ips: for(_ <- 0..:rand.uniform(4)//1, do: random_ip()) |> Enum.drop(1)
        )

      d
    end
  end

  defp random_ip do
    if :rand.uniform(2) == 1 do
      Enum.map_join(1..4, ".", fn _ -> :rand.uniform(256) - 1 end)
    else
      1..8
      |> Enum.map(fn _ -> :rand.uniform(65_536) - 1 end)
      |> List.to_tuple()
      |> :inet.ntoa()
      |> to_string()
    end
  end

  defp random_cidr do
    ip = random_ip()
    max = if String.contains?(ip, ":"), do: 128, else: 32
    if :rand.uniform(2) == 1, do: ip, else: "#{ip}/#{:rand.uniform(max + 1) - 1}"
  end

  # stable, readable json for fixtures: sorted keys, two-space indent, and anything
  # whose compact form fits on one line is written inline.
  defp pretty(term, indent \\ 0) do
    compact = compact(term)
    pad = String.duplicate("  ", indent)

    cond do
      String.length(compact) + byte_size(pad) <= 96 ->
        compact

      is_map(term) ->
        inner =
          term
          |> Enum.sort()
          |> Enum.map_join(",\n", fn {k, v} ->
            pad <> "  " <> JSON.encode!(k) <> ": " <> pretty(v, indent + 1)
          end)

        "{\n" <> inner <> "\n" <> pad <> "}"

      is_list(term) ->
        inner = Enum.map_join(term, ",\n", &(pad <> "  " <> pretty(&1, indent + 1)))
        "[\n" <> inner <> "\n" <> pad <> "]"
    end
  end

  defp compact(term) when is_map(term) do
    "{" <>
      (term
       |> Enum.sort()
       |> Enum.map_join(", ", fn {k, v} -> JSON.encode!(k) <> ": " <> compact(v) end)) <> "}"
  end

  defp compact(term) when is_list(term), do: "[" <> Enum.map_join(term, ", ", &compact/1) <> "]"
  defp compact(term), do: JSON.encode!(term)
end
