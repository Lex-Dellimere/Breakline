defmodule Gateway.StoreTest do
  # the fake clock agent is a registered name
  use ExUnit.Case, async: false

  import Gateway.TestSupport, only: [tmp_dir: 1]

  alias Breakline.AuditLog
  alias Gateway.Store

  @now ~U[2026-11-02 00:00:00Z]

  setup do
    start_supervised!({Gateway.Clock.Fake, now: @now})
    %{dir: tmp_dir("store")}
  end

  defp start_store(dir) do
    start_supervised!({Store, data_dir: dir, clock: Gateway.Clock.Fake, name: :test_store},
      restart: :temporary
    )

    :test_store
  end

  defp restart_store(dir) do
    stop_supervised!(:test_store)
    start_store(dir)
  end

  defp audit_path(dir), do: Path.join(dir, "audit.jsonl")

  test "command bytes round trip exactly and survive a restart", %{dir: dir} do
    store = start_store(dir)
    assert Store.load_command(store) == :none

    bytes = ~s({"envelope": {"weird": "spacing"}, "signature": "x"}\n)
    assert :ok = Store.save_command(bytes, store)
    assert Store.load_command(store) == {:ok, bytes}

    store = restart_store(dir)
    assert Store.load_command(store) == {:ok, bytes}

    # no temporary files left behind
    assert Enum.sort(File.ls!(dir)) == ["audit.jsonl", "command.json"]
  end

  test "verifier state keeps only version and nonces", %{dir: dir} do
    store = start_store(dir)
    assert Store.load_verifier_state(store) == :none

    verifier =
      Breakline.Command.Verifier.new(
        site_id: "s",
        public_keys: %{"k" => :binary.copy(<<1>>, 32)},
        last_version: 7,
        seen_nonces: %{"abc" => ~U[2026-11-02 01:00:00Z]}
      )

    assert :ok = Store.save_verifier_state(verifier, store)
    {:ok, json} = File.read(Path.join(dir, "verifier.json"))
    assert {:ok, %{"last_version" => 7, "seen_nonces" => _} = map} = JSON.decode(json)
    assert map_size(map) == 2

    assert Store.load_verifier_state(store) ==
             {:ok, %{last_version: 7, seen_nonces: %{"abc" => ~U[2026-11-02 01:00:00Z]}}}

    File.write!(Path.join(dir, "verifier.json"), ~s({"last_version": -1, "seen_nonces": {}}))
    assert {:error, _} = Store.load_verifier_state(store)
  end

  test "audit entries form a chain that continues across restarts", %{dir: dir} do
    store = start_store(dir)
    {:ok, r0} = Store.audit(%{"type" => "a"}, store)
    {:ok, r1} = Store.audit(%{"type" => "b"}, store)
    assert Store.audit_head(store) == {1, r1["hash"]}

    store = restart_store(dir)
    assert Store.audit_head(store) == {1, r1["hash"]}
    {:ok, r2} = Store.audit(%{"type" => "c"}, store)

    assert {:ok, [^r0, ^r1, ^r2]} = Store.read_audit(audit_path(dir))
    assert :ok = AuditLog.verify_chain([r0, r1, r2], expected_head: {2, r2["hash"]})
  end

  test "an edited audit file is moved aside and a new chain records it", %{dir: dir} do
    store = start_store(dir)
    for t <- ~w(a b c), do: {:ok, _} = Store.audit(%{"type" => t}, store)
    stop_supervised!(:test_store)

    original = File.read!(audit_path(dir))
    File.write!(audit_path(dir), String.replace(original, ~s("type":"b"), ~s("type":"x")))

    store = start_store(dir)
    moved = "audit.jsonl.broken-#{DateTime.to_unix(@now)}"
    assert File.exists?(Path.join(dir, moved))

    assert {:ok, [reset]} = Store.read_audit(audit_path(dir))
    assert reset["seq"] == 0

    assert %{"type" => "audit_chain_reset", "moved_to" => ^moved, "reason" => reason} =
             reset["entry"]

    assert reason =~ "hash_mismatch"
    assert Store.audit_head(store) == {0, reset["hash"]}
  end

  test "a torn final line is a broken chain too", %{dir: dir} do
    store = start_store(dir)
    {:ok, _} = Store.audit(%{"type" => "a"}, store)
    stop_supervised!(:test_store)

    File.write!(audit_path(dir), ~s({"seq":1,"prev), [:append])
    start_store(dir)

    assert {:ok, [reset]} = Store.read_audit(audit_path(dir))
    assert reset["entry"]["reason"] =~ "undecodable_line"
  end

  test "a second break in the same second does not overwrite the first", %{dir: dir} do
    File.write!(audit_path(dir), "garbage\n")
    start_store(dir)
    stop_supervised!(:test_store)
    File.write!(audit_path(dir), "more garbage\n")
    start_store(dir)

    broken = dir |> File.ls!() |> Enum.filter(&String.contains?(&1, "broken"))
    assert length(broken) == 2
  end
end
