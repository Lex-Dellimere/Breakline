defmodule Gateway.EnforcerTest do
  # registered names, the fake clock and the dns snapshot are global
  use ExUnit.Case, async: false

  import Gateway.TestSupport

  alias Breakline.Catalog
  alias Gateway.Clock.Fake
  alias Gateway.DNS.Snapshot
  alias Gateway.{Enforcer, Events, Store}
  alias Gateway.Firewall.Desired

  @tz "Australia/Sydney"
  # monday 2 november 2026, 11:00 in sydney (aedt, +11)
  @monday_11 ~U[2026-11-02 00:00:00Z]

  setup do
    Snapshot.clear()
    on_exit(&Snapshot.clear/0)

    {pub, priv} = keypair()
    {other_pub, other_priv} = keypair()

    start_supervised!({Fake, now: @monday_11})
    start_supervised!({Gateway.Firewall.Server, impl: Gateway.Firewall.FakeImpl})
    start_supervised!(Events)

    dir = tmp_dir("enforcer")
    ctx = %{dir: dir, priv: priv, pub: pub, other_pub: other_pub, other_priv: other_priv}
    start_enforcer(ctx)
    ctx
  end

  defp start_enforcer(ctx) do
    start_supervised!({Store, data_dir: ctx.dir, clock: Fake})

    start_supervised!(
      {Enforcer,
       site_id: site(),
       public_keys: %{"k1" => b64(ctx.pub)},
       lan_interfaces: ["eth1"],
       dns_port: 5300,
       tick_ms: 60_000,
       retry_ms: 20,
       clock: Fake}
    )

    # a call returns only after the boot continue (audit, first apply) has run
    Enforcer.status()
  end

  defp restart_enforcer(ctx) do
    stop_supervised!(Enforcer)
    stop_supervised!(Store)
    start_enforcer(ctx)
  end

  defp local(date, time) do
    date |> DateTime.new!(time, @tz, Tz.TimeZoneDatabase) |> DateTime.shift_zone!("Etc/UTC")
  end

  defp at_local(date, time) do
    Fake.set_now(local(date, time))
    Enforcer.evaluate()
  end

  defp submit!(ctx, version, attrs \\ [], opts \\ []) do
    assert :ok = Enforcer.submit(signed(ctx.priv, version, attrs, opts))
  end

  defp monday_window(starts, ends) do
    [recurring_windows: [%{id: "mon", days: [1], starts: starts, ends: ends}]]
  end

  describe "boot without a policy" do
    test "is locked, in the default mode, covering every catalog tool" do
      status = Enforcer.status()
      assert status.state == :locked
      assert status.reason == {:locked, :no_policy}
      assert status.mode == :monitor
      assert status.policy_version == nil
      assert status.firewall.in_sync?

      assert %Desired{locked?: true, mode: :monitor, dns_port: 5300} = fake_desired()
      assert fake_desired().exclusive_ports == Catalog.exclusive_ports(Catalog.ids())
      assert fake_desired().doh_ips != []

      snap = Snapshot.get()
      assert snap.locked?
      assert snap.mode == :monitor
      assert snap.tool_ids == Catalog.ids()
    end

    test "audits the boot and the first state", ctx do
      assert ["enforcer_started", "state_changed"] = audit_types(ctx.dir)
      [started, state] = audit_entries(ctx.dir)
      assert started["command"] == "none"
      assert state["reason"] == %{"rule" => "no_policy"}
      assert state["previous"] == nil
    end
  end

  describe "submit" do
    test "applies a valid policy and persists it first", ctx do
      wire = signed(ctx.priv, 1, monday_window(~T[10:00:00], ~T[12:00:00]))
      bytes = json(wire)
      assert :ok = Enforcer.submit(bytes)

      status = Enforcer.status()
      assert status.state == :open
      assert {:open, {:window, "mon", _}} = status.reason
      assert status.policy_version == 1
      assert status.mode == :enforce
      assert status.last_applied_at == @monday_11

      assert %Desired{locked?: false, mode: :enforce} = fake_desired()
      refute Snapshot.get().locked?
      assert Snapshot.get().tool_ids == ["anydesk", "n_central"]

      assert File.read!(Path.join(ctx.dir, "command.json")) == bytes
      assert {:ok, %{last_version: 1}} = Store.load_verifier_state()

      assert "policy_applied" in audit_types(ctx.dir)
      applied = Enum.find(audit_entries(ctx.dir), &(&1["type"] == "policy_applied"))
      assert applied["policy_version"] == 1
      assert applied["key_id"] == "k1"

      assert Enum.any?(Events.recent(), &(&1.type == :policy_applied))
    end

    test "a wire map is persisted in its canonical encoding", ctx do
      wire = signed(ctx.priv, 1)
      assert :ok = Enforcer.submit(wire)
      assert File.read!(Path.join(ctx.dir, "command.json")) == json(wire)
    end

    test "rejects every bad command and audits the reason", ctx do
      good = signed(ctx.priv, 5)
      tampered = put_in(good, ["envelope", "policy_version"], 6)

      cases = [
        {"not json", :malformed},
        {signed(ctx.other_priv, 1), :bad_signature},
        {signed(ctx.priv, 1, [], key_id: "k9"), :unknown_key},
        {tampered, :bad_signature},
        {signed(ctx.priv, 1, [], site_id: "other-site"), :wrong_site},
        {signed(ctx.priv, 1, [], issued_at: DateTime.add(@monday_11, -7200)), :expired},
        {signed(ctx.priv, 1, [], issued_at: DateTime.add(@monday_11, 3600)), :not_yet_valid},
        {signed(ctx.priv, 1, [], ttl_seconds: 2 * 86_400), :ttl_too_long},
        {signed(ctx.priv, 1, [], type: "reboot"), :unsupported_type},
        {signed(ctx.priv, 1, [], payload: %{"site_id" => site()}), :invalid_policy},
        {signed(ctx.priv, 1, site_id: "other-site"), :site_mismatch},
        {signed(ctx.priv, 1, [], policy_version: 2), :version_mismatch},
        {signed(ctx.priv, 0), :stale_version}
      ]

      for {input, expected} <- cases do
        result = Enforcer.submit(input)

        case expected do
          :invalid_policy -> assert {:error, {:invalid_policy, [_ | _]}} = result
          _ -> assert result == {:error, expected}, "expected #{expected}, got #{inspect(result)}"
        end
      end

      status = Enforcer.status()
      assert status.policy_version == nil
      assert status.last_version == 0
      refute File.exists?(Path.join(ctx.dir, "command.json"))

      reasons =
        for %{"type" => "command_rejected", "reason" => r} <- audit_entries(ctx.dir), do: r

      assert reasons == Enum.map(cases, fn {_, r} -> Atom.to_string(r) end)

      # a replay of an accepted command is stale
      assert :ok = Enforcer.submit(good)
      assert {:error, :stale_version} = Enforcer.submit(good)
      assert {:error, :stale_version} = Enforcer.submit(signed(ctx.priv, 4))
    end
  end

  describe "persistence" do
    test "policy and last_version survive a restart; older commands stay rejected", ctx do
      old = signed(ctx.priv, 1)
      submit!(ctx, 1)
      submit!(ctx, 2, monday_window(~T[10:00:00], ~T[12:00:00]))

      restart_enforcer(ctx)

      status = Enforcer.status()
      assert status.policy_version == 2
      assert status.last_version == 2
      assert status.state == :open
      assert {:error, :stale_version} = Enforcer.submit(old)
      assert {:error, :stale_version} = Enforcer.submit(signed(ctx.priv, 2))

      started = audit_entries(ctx.dir) |> Enum.filter(&(&1["type"] == "enforcer_started"))
      assert List.last(started)["command"] == "loaded"
    end

    test "an expired persisted command is still enforced after a restart", ctx do
      submit!(ctx, 1, monday_window(~T[10:00:00], ~T[12:00:00]), ttl_seconds: 60)
      Fake.advance(600)
      restart_enforcer(ctx)
      assert %{policy_version: 1, state: :open} = Enforcer.status()
    end

    test "a tampered command on disk is ignored at boot: no policy, locked", ctx do
      submit!(ctx, 3, monday_window(~T[10:00:00], ~T[12:00:00]))
      path = Path.join(ctx.dir, "command.json")
      {:ok, wire} = JSON.decode(File.read!(path))
      wire = put_in(wire, ["envelope", "payload", "tool_ids"], [])
      File.write!(path, json(wire))

      restart_enforcer(ctx)

      status = Enforcer.status()
      assert status.policy_version == nil
      assert status.reason == {:locked, :no_policy}
      assert %Desired{locked?: true} = fake_desired()
      assert Snapshot.get().locked?
      # the version floor survives in verifier.json
      assert status.last_version == 3

      started = audit_entries(ctx.dir) |> Enum.filter(&(&1["type"] == "enforcer_started"))
      assert List.last(started)["command"] == "rejected: bad_signature"
    end

    test "a lost verifier.json falls back to the persisted command's version", ctx do
      submit!(ctx, 4)
      File.rm!(Path.join(ctx.dir, "verifier.json"))
      restart_enforcer(ctx)

      assert %{last_version: 4, policy_version: 4} = Enforcer.status()
      assert {:error, :stale_version} = Enforcer.submit(signed(ctx.priv, 4))
    end
  end

  describe "schedule driven transitions" do
    test "a recurring window opens and closes", ctx do
      submit!(ctx, 1, monday_window(~T[12:00:00], ~T[13:00:00]))

      status = Enforcer.status()
      assert status.state == :locked
      assert status.reason == {:locked, :default}
      assert status.next_change == local(~D[2026-11-02], ~T[12:00:00])
      assert fake_desired().locked?
      assert Snapshot.get().locked?

      at_local(~D[2026-11-02], ~T[12:00:00])
      assert Enforcer.status().state == :open
      refute fake_desired().locked?
      refute Snapshot.get().locked?

      at_local(~D[2026-11-02], ~T[12:59:59])
      assert Enforcer.status().state == :open

      at_local(~D[2026-11-02], ~T[13:00:00])
      assert Enforcer.status().state == :locked
      assert fake_desired().locked?
      assert Snapshot.get().locked?

      states =
        for %{"type" => "state_changed"} = e <- audit_entries(ctx.dir),
            do: {e["state"], e["reason"]["rule"]}

      assert states == [
               {"locked", "no_policy"},
               {"locked", "default"},
               {"open", "window"},
               {"locked", "default"}
             ]

      assert Events.recent() |> Enum.filter(&(&1.type == :state_changed)) |> length() == 4
    end

    test "break-glass opens until its end", ctx do
      until = DateTime.add(@monday_11, 600)
      submit!(ctx, 1, break_glass: %{until: until, approved_by: "alice"})

      assert {:open, {:break_glass, _}} = Enforcer.status().reason
      assert Enforcer.status().next_change == until
      refute fake_desired().locked?

      Fake.set_now(until)
      Enforcer.evaluate()
      assert Enforcer.status().reason == {:locked, :default}
      assert fake_desired().locked?
    end

    test "an advisory lock wins over an open window and break-glass", ctx do
      lock_end = DateTime.add(@monday_11, 300)

      submit!(
        ctx,
        1,
        monday_window(~T[10:00:00], ~T[13:00:00]) ++
          [
            break_glass: %{until: DateTime.add(@monday_11, 3600), approved_by: "alice"},
            advisory_locks: [
              %{id: "kev-1", reason: "anydesk kev", source: "kev:CVE-1", expires_at: lock_end}
            ]
          ]
      )

      assert {:locked, {:advisory_lock, %{id: "kev-1"}}} = Enforcer.status().reason
      assert fake_desired().locked?
      assert Snapshot.get().locked?

      Fake.set_now(lock_end)
      Enforcer.evaluate()
      assert {:open, {:break_glass, _}} = Enforcer.status().reason
      refute fake_desired().locked?

      lock = Enum.find(audit_entries(ctx.dir), &(&1["reason"]["rule"] == "advisory_lock"))
      assert lock["reason"]["source"] == "kev:CVE-1"
    end

    test "an unsynced clock locks, and syncing again reopens", ctx do
      submit!(ctx, 1, monday_window(~T[10:00:00], ~T[13:00:00]))
      assert Enforcer.status().state == :open

      Fake.set_synced(false)
      Enforcer.evaluate()
      status = Enforcer.status()
      assert status.reason == {:locked, :clock_unsynced}
      refute status.clock_synced?
      assert status.next_change == nil
      assert fake_desired().locked?
      assert Snapshot.get().locked?

      Fake.set_synced(true)
      Enforcer.evaluate()
      assert Enforcer.status().state == :open
      refute fake_desired().locked?

      rules =
        for %{"type" => "state_changed"} = e <- audit_entries(ctx.dir), do: e["reason"]["rule"]

      assert Enum.take(rules, -2) == ["clock_unsynced", "window"]
    end

    test "mode and site hosts reach the firewall and the resolver", ctx do
      submit!(ctx, 1,
        mode: :monitor,
        tool_ids: ["anydesk"],
        site_hosts: ["rmm.client.example", "10.9.9.7/24", "192.0.2.10", "bad/cidr/x"]
      )

      d = fake_desired()
      assert d.mode == :monitor
      assert d.locked?
      assert d.block_cidrs == ["10.9.9.0/24", "192.0.2.10"]
      assert d.exclusive_ports == Catalog.exclusive_ports(["anydesk"])

      snap = Snapshot.get()
      assert snap.mode == :monitor
      assert snap.tool_ids == ["anydesk"]
      assert snap.site_hostnames == ["rmm.client.example"]
    end

    test "nothing is re-applied when nothing changed" do
      %{state: %{apply_count: count}} = Gateway.Firewall.snapshot()
      Enforcer.evaluate()
      Enforcer.evaluate()
      assert %{state: %{apply_count: ^count}} = Gateway.Firewall.snapshot()
    end
  end

  test "the enforcer wakes itself at the next change, sooner than the tick", ctx do
    Fake.set_now(local(~D[2026-11-02], ~T[11:59:59]))
    submit!(ctx, 1, monday_window(~T[12:00:00], ~T[13:00:00]))
    assert Enforcer.status().state == :locked

    # the fake clock does not move by itself: move it, then wait for the timer
    Fake.advance(1)
    eventually(fn -> Enforcer.status().state == :open end, 3000)
  end

  test "a restarted firewall server gets the desired state again" do
    desired = fake_desired()
    old = Process.whereis(Gateway.Firewall.Server)
    Process.exit(old, :kill)

    eventually(fn ->
      pid = Process.whereis(Gateway.Firewall.Server)
      pid && pid != old && fake_desired() == desired
    end)

    assert Enforcer.status().firewall.in_sync?
  end
end
