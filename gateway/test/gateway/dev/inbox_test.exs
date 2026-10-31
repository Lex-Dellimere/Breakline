defmodule Gateway.Dev.InboxTest do
  use ExUnit.Case, async: false

  import Gateway.TestSupport

  alias Gateway.Clock.Fake
  alias Gateway.Dev.Inbox

  setup do
    Gateway.DNS.Snapshot.clear()
    on_exit(&Gateway.DNS.Snapshot.clear/0)

    {pub, priv} = keypair()
    dir = tmp_dir("inbox")
    start_supervised!({Fake, now: ~U[2026-11-02 00:00:00Z]})
    start_supervised!({Gateway.Firewall.Server, impl: Gateway.Firewall.FakeImpl})
    start_supervised!({Gateway.Store, data_dir: Path.join(dir, "data"), clock: Fake})

    start_supervised!(
      {Gateway.Enforcer,
       site_id: site(),
       public_keys: %{"k1" => b64(pub)},
       lan_interfaces: ["eth1"],
       tick_ms: 60_000,
       clock: Fake}
    )

    inbox = Path.join(dir, "inbox")
    start_supervised!({Inbox, dir: inbox, interval_ms: 60_000})
    %{inbox: inbox, priv: priv}
  end

  test "submits each file and sorts it into processed or rejected", ctx do
    File.write!(Path.join(ctx.inbox, "a.json"), json(signed(ctx.priv, 1)))
    File.write!(Path.join(ctx.inbox, "b.json"), json(signed(ctx.priv, 1)))
    File.write!(Path.join(ctx.inbox, "c.json.tmp"), "half written")

    assert Inbox.poll() == [{"a.json", :ok}, {"b.json", {:error, :stale_version}}]
    assert File.ls!(Path.join(ctx.inbox, "processed")) == ["a.json"]
    assert File.ls!(Path.join(ctx.inbox, "rejected")) == ["b.json"]
    assert File.exists?(Path.join(ctx.inbox, "c.json.tmp"))
    assert Gateway.Enforcer.status().policy_version == 1
  end
end
