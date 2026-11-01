defmodule Gateway.TrafficCase do
  @moduledoc false
  # the traffic scenarios, shared by every topology:
  #
  #   use Gateway.TrafficCase, topology: :router
  #
  # setup_all starts one container (see Gateway.Traffic.start!/2); the tests in a
  # module run one after another against it, and each sets the policy it needs.
  # modules run in parallel, one container each.

  defmacro __using__(opts) do
    topology = Keyword.fetch!(opts, :topology)

    quote do
      use ExUnit.Case, async: true

      import Gateway.Traffic

      @moduletag :traffic
      @moduletag timeout: 300_000

      # dnsmasq in upstream answers these, see test/fixtures/traffic/topology.sh
      @rmm4 "198.51.100.10"
      @rmm6 "2001:db8::10"
      @vanity4 "198.51.100.21"
      @vanity6 "2001:db8::21"
      @web4 "203.0.113.80"
      @web6 "2001:db8::80"
      # an address nothing resolves to, for the tool-only ports
      @any4 "192.0.2.50"
      @any6 "2001:db8::50"
      @doh4 "1.1.1.1"
      @doh6 "2606:4700:4700::1111"
      @catalog ~w(boot.net.anydesk.com relay-01.net.anydesk.com live.screenconnect.com)
      @vanity "remote.vanity.test"
      @web "shop.example.test"
      # a real resolver address (a rogue resolver listens there) and one where nothing
      # listens: both must be answered by the gateway
      @resolvers4 ["8.8.8.8", "192.0.2.53"]
      @resolvers6 ["2001:4860:4860::8888", "2001:db8::53"]

      setup_all do
        {:ok, ctx: start!(unquote(topology))}
      end

      # locks, then resolves the rmm names so the shadow lookup fills rmm4 / rmm6
      defp learn!(ctx) do
        lock!(ctx)

        for name <- ["boot.net.anydesk.com", @vanity], type <- ["A", "AAAA"] do
          assert %{status: :nxdomain} = dig(ctx, "8.8.8.8", name, type: type)
        end

        for {set, ip} <- [
              {"rmm4", @rmm4},
              {"rmm6", @rmm6},
              {"rmm4", @vanity4},
              {"rmm6", @vanity6}
            ],
            do: await_member(ctx, set, ip)
      end

      defp locked_drops(:v4) do
        %{
          {:tcp, @rmm4, 443} => :drop,
          {:tcp, @vanity4, 443} => :drop,
          {:tcp, @any4, 6568} => :drop,
          {:tcp, @any4, 5938} => :drop,
          {:udp, @any4, 5938} => :drop,
          {:tcp, @web4, 853} => :drop,
          {:udp, @web4, 853} => :drop,
          {:tcp, @doh4, 443} => :drop,
          {:udp, @doh4, 443} => :drop
        }
      end

      defp locked_drops(:v6) do
        %{
          {:tcp, @rmm6, 443} => :drop,
          {:tcp, @vanity6, 443} => :drop,
          {:tcp, @any6, 6568} => :drop,
          {:tcp, @any6, 5938} => :drop,
          {:udp, @any6, 5938} => :drop,
          {:tcp, @web6, 853} => :drop,
          {:udp, @web6, 853} => :drop,
          {:tcp, @doh6, 443} => :drop,
          {:udp, @doh6, 443} => :drop
        }
      end

      defp web_passes(:v4),
        do: %{
          {:tcp, @web4, 443} => :pass,
          {:tcp, @web4, 80} => :pass,
          {:udp, @web4, 443} => :pass
        }

      defp web_passes(:v6),
        do: %{
          {:tcp, @web6, 443} => :pass,
          {:tcp, @web6, 80} => :pass,
          {:udp, @web6, 443} => :pass
        }

      defp all_pass(specs), do: Map.new(specs, fn {spec, _} -> {spec, :pass} end)

      test "client dns to any resolver address is answered by the gateway", %{ctx: ctx} do
        lock!(ctx)

        for server <- @resolvers4 ++ @resolvers6, tcp <- [false, true], type <- ["A", "AAAA"] do
          where = "#{type} via #{server}#{if tcp, do: " over tcp"}"
          expected = if type == "A", do: [@web4], else: [@web6]

          assert %{status: :noerror, answers: ^expected} =
                   dig(ctx, server, @web, type: type, tcp: tcp),
                 where

          assert %{status: :nxdomain} =
                   dig(ctx, server, "boot.net.anydesk.com", type: type, tcp: tcp),
                 where
        end
      end

      defp locked_case(ctx, family) do
        {server, type} =
          if family == :v4, do: {"8.8.8.8", "A"}, else: {"2001:4860:4860::8888", "AAAA"}

        lock!(ctx)

        for name <- @catalog ++ [@vanity] do
          assert %{status: :nxdomain, answers: []} = dig(ctx, server, name, type: type), name
        end

        {set, ips} =
          if family == :v4, do: {"rmm4", [@rmm4, @vanity4]}, else: {"rmm6", [@rmm6, @vanity6]}

        for ip <- ips, do: await_member(ctx, set, ip)

        assert_probes(ctx, Map.merge(locked_drops(family), web_passes(family)))

        web = if family == :v4, do: [@web4], else: [@web6]
        assert %{status: :noerror, answers: ^web} = dig(ctx, server, @web, type: type)
      end

      test(
        "locked and enforcing: catalog names get nxdomain, rmm traffic drops (ipv4)",
        %{ctx: ctx},
        do: locked_case(ctx, :v4)
      )

      test(
        "locked and enforcing: catalog names get nxdomain, rmm traffic drops (ipv6)",
        %{ctx: ctx},
        do: locked_case(ctx, :v6)
      )

      test "an open window lets the same rmm traffic through", %{ctx: ctx} do
        learn!(ctx)
        open!(ctx, 600)

        assert %{status: :noerror, answers: [@rmm4]} = dig(ctx, "8.8.8.8", "boot.net.anydesk.com")

        assert %{status: :noerror, answers: [@vanity6]} =
                 dig(ctx, "2001:4860:4860::8888", @vanity, type: "AAAA")

        # dot and doh stay dropped whatever the schedule says
        always =
          [:tcp, :udp]
          |> Enum.flat_map(
            &[{&1, @web4, 853}, {&1, @web6, 853}, {&1, @doh4, 443}, {&1, @doh6, 443}]
          )

        expected =
          Map.merge(all_pass(locked_drops(:v4)), all_pass(locked_drops(:v6)))
          |> Map.merge(Map.new(always, &{&1, :drop}))

        assert_probes(ctx, expected)
      end

      test "when the window ends, established rmm sessions are cut", %{ctx: ctx} do
        learn!(ctx)
        until = open!(ctx, 15)
        sessions = [start_session!(ctx, @rmm4, 443), start_session!(ctx, @rmm6, 443)]

        await_status(ctx, &(&1.state == :locked), 30_000)
        ends = DateTime.to_unix(until)

        for out <- sessions do
          last = await_cut(ctx, out)
          stop_session(ctx, out)
          assert last > ends - 1.0, "#{out} stopped #{ends - last}s before the window ended"
          assert last < ends + 3.0, "#{out} was cut #{last - ends}s after the window ended"
        end
      end

      test "a lock policy cuts established rmm sessions at once", %{ctx: ctx} do
        learn!(ctx)
        open!(ctx, 600)

        sessions = [
          start_session!(ctx, @rmm4, 443),
          start_session!(ctx, @any4, 6568),
          start_session!(ctx, @any6, 5938)
        ]

        submitted = now()
        lock!(ctx)
        locked = now()

        for out <- sessions do
          last = await_cut(ctx, out)
          stop_session(ctx, out)
          assert last > submitted - 1.0, "#{out} stopped before the lock"
          assert last < locked + 3.0, "#{out} was cut #{last - locked}s after the lock"
        end
      end

      test "monitor mode drops nothing and counts new connections", %{ctx: ctx} do
        lock!(ctx, :monitor)

        # catalog names are forwarded, and the answers still feed the sets
        assert %{status: :noerror, answers: [@rmm4]} = dig(ctx, "8.8.8.8", "boot.net.anydesk.com")

        assert %{status: :noerror, answers: [@rmm6]} =
                 dig(ctx, "8.8.8.8", "boot.net.anydesk.com", type: "AAAA")

        await_member(ctx, "rmm4", @rmm4)
        await_member(ctx, "rmm6", @rmm6)

        assert_probes(ctx, Map.merge(all_pass(locked_drops(:v4)), all_pass(locked_drops(:v6))))

        before = counters(ctx)
        assert Enum.all?(probe_times(ctx, {:tcp, @any4, 6568}, 15), &(&1 == :pass))
        assert Enum.all?(probe_times(ctx, {:tcp, @rmm4, 443}, 12), &(&1 == :pass))
        assert Enum.all?(probe_times(ctx, {:tcp, @rmm6, 443}, 3), &(&1 == :pass))
        assert Enum.all?(probe_times(ctx, {:udp, @any4, 5938}, 4), &(&1 == :pass))
        counted = counters(ctx)

        delta = fn key -> counted[key] - before[key] end
        assert delta.({"port", ["tcp"]}) == 15
        assert delta.({"rmm", ["ip"]}) == 12
        assert delta.({"rmm", ["ip6"]}) == 3
        assert delta.({"port", ["udp"]}) == 4

        # a session with many packets is one connection
        before = counters(ctx)
        out = start_session!(ctx, @any4, 6568)
        await(fn -> length(session(ctx, out)) >= 10 end, 10_000, "10 echoes")
        stop_session(ctx, out)
        assert counters(ctx)[{"port", ["tcp"]}] - before[{"port", ["tcp"]}] == 1

        # the log is rate limited on every rule. the kernel does not log from a
        # non-init namespace (nf_log_all_netns is 0), so only the rule is checked
        for rule <- forward_rules(ctx) do
          assert %{"limit" => %{"rate" => 30, "per" => "minute", "burst" => 10}} in rule["expr"]
          assert Enum.any?(rule["expr"], &match?(%{"log" => _}, &1))
          refute Enum.any?(rule["expr"], &match?(%{"drop" => _}, &1))
        end

        events = rpc!(ctx, "Gateway.Events.recent(500)")

        assert Enum.any?(
                 events,
                 &match?(%{type: :would_block, qname: "boot.net.anydesk.com"}, &1)
               )
      end

      test "the table outlives a killed beam, and a restart applies the state again",
           %{ctx: ctx} do
        learn!(ctx)
        version = status(ctx).policy_version
        kill_gateway!(ctx)

        assert {:ok, _} = nft(ctx, "table inet breakline")
        assert @rmm4 in set_members(ctx, "rmm4")

        assert_probes(ctx, %{
          {:tcp, @rmm4, 443} => :drop,
          {:tcp, @rmm6, 443} => :drop,
          {:tcp, @any4, 6568} => :drop,
          {:tcp, @web4, 853} => :drop,
          {:tcp, @web4, 443} => :pass
        })

        # the redirect still sends client dns to :53, where nothing listens now
        for tcp <- [false, true] do
          assert %{status: :refused} = dig(ctx, "8.8.8.8", @web, tcp: tcp)
          assert %{status: :refused} = dig(ctx, "2001:4860:4860::8888", @web, tcp: tcp)
        end

        restarted = DateTime.utc_now() |> DateTime.truncate(:second)
        start_gateway!(ctx)
        status = await_status(ctx, & &1.firewall.in_sync?)

        assert %{state: :locked, mode: :enforce, policy_version: ^version} = status
        assert DateTime.compare(status.last_applied_at, restarted) != :lt
        assert %{status: :nxdomain} = dig(ctx, "8.8.8.8", "boot.net.anydesk.com")
        assert %{status: :noerror, answers: [@web4]} = dig(ctx, "8.8.8.8", @web)
        assert_probes(ctx, %{{:tcp, @rmm4, 443} => :drop, {:tcp, @any4, 6568} => :drop})

        # a window that ends while the beam is down stays open until it is back
        until = open!(ctx, 8)
        kill_gateway!(ctx)
        ended = DateTime.add(until, 1)
        await(fn -> DateTime.after?(DateTime.utc_now(), ended) end, 15_000, "the window to end")
        assert_probes(ctx, %{{:tcp, @rmm4, 443} => :pass, {:tcp, @any4, 6568} => :pass})

        start_gateway!(ctx)
        await_status(ctx, &(&1.state == :locked))
        assert_probes(ctx, %{{:tcp, @rmm4, 443} => :drop, {:tcp, @any4, 6568} => :drop})
      end

      test "a flushed ruleset is applied again on the next evaluation", %{ctx: ctx} do
        lock!(ctx)
        # what a restart of debian's nftables.service does
        exec!(ctx, ["nft", "flush", "ruleset"])
        assert {:error, _} = nft(ctx, "table inet breakline")

        await(fn -> match?({:ok, _}, nft(ctx, "table inet breakline")) end, 20_000, "the table")

        # the resolved sets went with the flush; a lookup fills them again
        assert %{status: :nxdomain} = dig(ctx, "8.8.8.8", "boot.net.anydesk.com")
        await_member(ctx, "rmm4", @rmm4)
        assert_probes(ctx, %{{:tcp, @rmm4, 443} => :drop, {:tcp, @any4, 6568} => :drop})
      end

      if unquote(topology) == :router do
        test "the resolver does not answer the wan side", %{ctx: ctx} do
          lock!(ctx)

          for server <- ["10.20.0.1", "fd00:20::1"], tcp <- [false, true] do
            assert %{status: :timeout} = dig(ctx, server, @web, tcp: tcp, from: :upstream)
          end

          # the lan side still gets answers from the gateway's own address
          assert %{status: :noerror, answers: [@web4]} = dig(ctx, "10.10.0.1", @web)
        end
      end

      if unquote(topology) == :bridge do
        test "br_netfilter's sysctls are on and the firewall reports no problem", %{ctx: ctx} do
          for sysctl <- ["bridge-nf-call-iptables", "bridge-nf-call-ip6tables"] do
            assert exec!(ctx, ["cat", "/proc/sys/net/bridge/#{sysctl}"]) == "1\n"
          end

          assert status(ctx).firewall.host_problems == []
        end

        test "a bridge port as the lan interface lets client dns through, and says so",
             %{ctx: ctx} do
          on_exit(fn ->
            kill_gateway!(ctx)
            write_env(ctx, ctx.env)
            start_gateway!(ctx)
          end)

          kill_gateway!(ctx)
          write_env(ctx, Map.put(ctx.env, "BREAKLINE_LAN_INTERFACES", "lan0"))
          start_gateway!(ctx)
          lock!(ctx)

          assert [{:bridge_port, "lan0", "br0"}] = status(ctx).firewall.host_problems
          # the rogue resolver answers: the redirect never matched
          assert %{answers: ["192.0.2.66"]} = dig(ctx, "8.8.8.8", "boot.net.anydesk.com")
        end
      end
    end
  end
end
