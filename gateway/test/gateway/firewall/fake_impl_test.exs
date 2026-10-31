defmodule Gateway.Firewall.FakeImplTest do
  use ExUnit.Case, async: true

  alias Gateway.Firewall.{Desired, FakeImpl}

  defp clock do
    {:ok, agent} = Agent.start_link(fn -> 1_000 end)
    {fn -> Agent.get(agent, & &1) end, fn s -> Agent.update(agent, &(&1 + s)) end}
  end

  defp desired(locked?) do
    {:ok, d} =
      Desired.new(locked?: locked?, mode: :enforce, lan_interfaces: ["eth1"], dns_port: 5353)

    d
  end

  test "records the applied desired state" do
    {:ok, s} = FakeImpl.init([])
    assert %{desired: nil, apply_count: 0, resolved: %{}} = FakeImpl.snapshot(s)
    {:ok, s} = FakeImpl.apply_desired(desired(true), s)
    {:ok, s} = FakeImpl.apply_desired(desired(false), s)
    assert %{desired: %Desired{locked?: false}, apply_count: 2} = FakeImpl.snapshot(s)
  end

  test "clamps ttls, expires entries and survives applies" do
    {now, advance} = clock()
    {:ok, s} = FakeImpl.init(clock: now, ttl_floor: 60, ttl_cap: 600)

    {:ok, s} =
      FakeImpl.add_resolved(
        [
          {{192, 0, 2, 1}, 5, "anydesk"},
          {{0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}, 9_999, "teamviewer"}
        ],
        s
      )

    {:ok, s} = FakeImpl.apply_desired(desired(true), s)

    assert FakeImpl.snapshot(s).resolved == %{
             {192, 0, 2, 1} => %{tool_id: "anydesk", expires_in: 60},
             {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1} => %{tool_id: "teamviewer", expires_in: 600}
           }

    advance.(60)
    assert Map.keys(FakeImpl.snapshot(s).resolved) == [{0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}]
    advance.(540)
    assert FakeImpl.snapshot(s).resolved == %{}
  end

  test "re-adding resets the expiry, and the longest ttl wins within one call" do
    {now, advance} = clock()
    {:ok, s} = FakeImpl.init(clock: now, ttl_floor: 60, ttl_cap: 600)
    ip = {192, 0, 2, 1}
    {:ok, s} = FakeImpl.add_resolved([{ip, 500, "a"}, {ip, 100, "a"}], s)
    assert FakeImpl.snapshot(s).resolved[ip].expires_in == 500
    advance.(10)
    {:ok, s} = FakeImpl.add_resolved([{ip, 100, "a"}], s)
    assert FakeImpl.snapshot(s).resolved[ip].expires_in == 100
  end

  test "keeps valid entries and reports invalid ones" do
    {:ok, s} = FakeImpl.init([])
    bad = [{{300, 0, 0, 1}, 60, "a"}, {"1.2.3.4", 60, "a"}, {{1, 2, 3, 4}, "60", "a"}, :x]

    assert {:error, {:invalid_entries, ^bad}, s} =
             FakeImpl.add_resolved([{{192, 0, 2, 1}, 60, "a"} | bad], s)

    assert Map.keys(FakeImpl.snapshot(s).resolved) == [{192, 0, 2, 1}]
  end

  test "fail_apply makes every apply fail" do
    {:ok, s} = FakeImpl.init(fail_apply: :boom)
    assert {:error, :boom, _} = FakeImpl.apply_desired(desired(true), s)
  end
end
