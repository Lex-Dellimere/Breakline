defmodule Gateway.FirewallTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Gateway.Firewall
  alias Gateway.Firewall.{Desired, FakeImpl, Server}

  doctest Firewall

  defp desired(locked?) do
    {:ok, d} =
      Desired.new(locked?: locked?, mode: :enforce, lan_interfaces: ["eth1"], dns_port: 5353)

    d
  end

  defp start(name, impl_opts \\ []) do
    start_supervised!({Server, name: name, impl: FakeImpl, impl_opts: impl_opts})
    name
  end

  test "clamp_ttl and ttl_bounds" do
    assert Firewall.clamp_ttl(10, 60, 600) == 60
    assert Firewall.clamp_ttl(100, 60, 600) == 100
    assert Firewall.clamp_ttl(1_000, 60, 600) == 600
    assert Firewall.ttl_bounds([]) == {3_600, 86_400}
    assert Firewall.ttl_bounds(ttl_floor: 5, ttl_cap: 5) == {5, 5}
    assert_raise ArgumentError, fn -> Firewall.ttl_bounds(ttl_floor: 10, ttl_cap: 5) end
    assert_raise ArgumentError, fn -> Firewall.ttl_bounds(ttl_floor: 0) end
  end

  test "the server starts empty and applies desired state" do
    name = start(:fw_apply)

    assert %{impl: FakeImpl, desired: nil, last_error: nil, state: %{apply_count: 0}} =
             Firewall.snapshot(name)

    assert :ok = Firewall.apply_desired(desired(true), name)
    assert %{desired: %Desired{locked?: true}, state: %{apply_count: 1}} = Firewall.snapshot(name)
  end

  test "add_resolved is a cast that reaches the impl" do
    name = start(:fw_resolved)
    assert :ok = Firewall.add_resolved([{{192, 0, 2, 1}, 30, "anydesk"}], name)

    assert %{state: %{resolved: %{{192, 0, 2, 1} => %{tool_id: "anydesk"}}}} =
             Firewall.snapshot(name)
  end

  test "an apply failure is returned and keeps the last good desired state" do
    name = start(:fw_fail)
    :ok = Firewall.apply_desired(desired(true), name)
    :sys.replace_state(name, fn s -> put_in(s.state.fail_apply, :boom) end)

    log =
      capture_log(fn -> assert {:error, :boom} = Firewall.apply_desired(desired(false), name) end)

    assert log =~ "firewall apply failed"

    assert %{desired: %Desired{locked?: true}, last_error: {:apply, :boom}} =
             Firewall.snapshot(name)
  end

  test "an add_resolved failure is logged and the server keeps running" do
    name = start(:fw_bad_resolved)

    log =
      capture_log(fn ->
        Firewall.add_resolved([:junk], name)

        assert %{last_error: {:add_resolved, {:invalid_entries, [:junk]}}} =
                 Firewall.snapshot(name)
      end)

    assert log =~ "add_resolved failed"
  end

  test "calls report not_running and casts are no-ops without a server" do
    assert Firewall.apply_desired(desired(true), :fw_missing) == {:error, :not_running}
    assert Firewall.snapshot(:fw_missing) == {:error, :not_running}
    assert Firewall.add_resolved([{{192, 0, 2, 1}, 30, "a"}], :fw_missing) == :ok
  end

  test "the default name is the server module" do
    assert Server.child_spec(impl: FakeImpl).id == Server
    pid = start_supervised!({Server, impl: FakeImpl})
    assert Process.whereis(Server) == pid
    assert :ok = Firewall.apply_desired(desired(false))
    assert %{desired: %Desired{locked?: false}} = Firewall.snapshot()
  end
end
