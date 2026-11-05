# a terminal simulation of breakline: one monday at a physio clinic.
#
#   cd gateway && mix run --no-start sim/breakline_sim.exs      (SIM_FAST=1 skips the pauses)
#
# real: the gateway's enforcer (verifier, store, audit chain, schedule, firewall server on
# the fake impl), the dns resolver on a free localhost port, the event buffer, and from core
# the policy, schedule, signed commands, catalog (domains, kev matching) and audit log.
# simulated: the cloud (this script signs with core, as the cloud does), the people, the
# upstream dns (a canned fake from test/support) and the clock (Gateway.Clock.Fake).
# it listens on one random localhost port only: no root, no nft, no cloud, no dev gateway.

Code.require_file("../test/support/fake_upstream.ex", __DIR__)

defmodule Sim.Out do
  @moduledoc false
  # coloured actor tags, verdicts and the pauses between beats

  @colours %{msp: 34, clinic: 32, cloud: 35, gateway: 36, attacker: 31}

  def color?, do: System.get_env("NO_COLOR") in [nil, ""] and IO.ANSI.enabled?()
  def paint(text, code), do: if(color?(), do: "\e[#{code}m#{text}\e[0m", else: text)

  def say(who, text),
    do: IO.puts(paint(String.pad_trailing("[#{who}]", 11), @colours[who]) <> text)

  def verdict(text, good?), do: paint(text, if(good?, do: "1;32", else: "1;31"))
  def dim(text), do: paint(text, "2")

  def header(n, title) do
    pause(900)
    IO.puts("\n" <> paint("#{n}. #{title}", "1"))
  end

  def pause(ms \\ 650), do: if(System.get_env("SIM_FAST") in [nil, ""], do: Process.sleep(ms))
end

defmodule Sim.Cloud do
  @moduledoc false
  # the cloud's job, done with core: keep the site's policy, bump the version on every
  # change, sign it. nothing here is reached over a network.

  alias Breakline.{Command, Policy}

  @site "bayside-physio"
  @key_id "cloud-2026-11"

  def site, do: @site
  def key_id, do: @key_id

  def start(priv) do
    base = %{
      site_id: @site,
      mode: :enforce,
      time_zone: "Australia/Sydney",
      tool_ids: ["anydesk"],
      # the standing window, sunday 02:00 to 04:00
      recurring_windows: [%{id: "weekly", days: [7], starts: ~T[02:00:00], ends: ~T[04:00:00]}]
    }

    Agent.start_link(fn -> %{priv: priv, version: 0, site: base} end, name: __MODULE__)
  end

  @doc "merges `change` over the site's policy, bumps the version and signs"
  def publish(change, ttl_seconds) do
    Agent.get_and_update(__MODULE__, fn s ->
      site = Map.merge(s.site, change)
      wire = sign(s.priv, @key_id, s.version + 1, site, ttl_seconds)
      {{s.version + 1, wire}, %{s | site: site, version: s.version + 1}}
    end)
  end

  def current, do: Agent.get(__MODULE__, & &1.site)

  @doc "signs a policy command. the attacker uses it too, with a key of their own"
  def sign(priv, key_id, version, site, ttl_seconds) do
    {:ok, policy} = Policy.new(Map.put(site, :version, version))

    [
      type: "policy",
      site_id: @site,
      policy_version: version,
      issued_at: Gateway.Clock.Fake.now(),
      ttl_seconds: ttl_seconds,
      payload: Policy.to_map(policy)
    ]
    |> Command.new!()
    |> Command.sign(key_id, priv)
  end
end

defmodule Sim do
  @moduledoc false

  alias Breakline.{AuditLog, Catalog, Command, Policy, Schedule}
  alias Gateway.Clock.Fake
  alias Gateway.{Enforcer, Events, FakeUpstream, Store}
  import Sim.Out

  @tz "Australia/Sydney"
  # what the canned upstream knows. 203.0.113.0/24 is documentation space
  @answers %{
    "app.cliniko.com" => [{:a, "app.cliniko.com", {203, 0, 113, 50}, 300}],
    "boot.net.anydesk.com" => [{:a, "boot.net.anydesk.com", {203, 0, 113, 10}, 60}],
    "relay-7f3a.net.anydesk.com" => [{:a, "relay-7f3a.net.anydesk.com", {203, 0, 113, 11}, 60}]
  }
  # a record in the shape of the cisa kev feed. the cve id is made up
  @kev %{
    "cveID" => "CVE-2026-99001",
    "vendorProject" => "AnyDesk",
    "product" => "AnyDesk",
    "vulnerabilityName" => "AnyDesk Relay Authentication Bypass Vulnerability",
    "dateAdded" => "2026-11-02"
  }

  def run do
    Logger.configure(level: :error)
    {pub, priv} = Command.generate_keypair()
    {:ok, _} = Sim.Cloud.start(priv)
    {:ok, _} = Fake.start_link(now: local(9, 0))
    dir = Path.join(System.tmp_dir!(), "breakline-sim-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    upstream = FakeUpstream.start(@answers)

    children =
      Gateway.Application.children(
        site_id: Sim.Cloud.site(),
        public_keys: %{Sim.Cloud.key_id() => Base.url_encode64(pub, padding: false)},
        lan_interfaces: ["eth1"],
        data_dir: dir,
        clock: Fake,
        tick_ms: 60_000,
        dns_port: 5300,
        default_mode: :enforce,
        firewall_impl: Gateway.Firewall.FakeImpl,
        inbox_dir: nil,
        uplink: nil,
        # port 0 picks a free port, so a dev gateway on 5300 is left alone
        dns: [ip: {127, 0, 0, 1}, port: 0, upstreams: [upstream], timeout_ms: 500]
      )

    {:ok, sup} = Supervisor.start_link(children, strategy: :one_for_one)
    Enforcer.status()

    try do
      story(Gateway.DNS.port(Gateway.DNS.Supervisor), dir)
    after
      Supervisor.stop(sup)
      File.rm_rf!(dir)
    end
  end

  # time. the fake clock only moves when the story moves it

  defp local(h, m) do
    ~D[2026-11-02]
    |> DateTime.new!(Time.new!(h, m, 0), @tz, Breakline.time_zone_database())
    |> DateTime.shift_zone!("Etc/UTC")
  end

  defp fmt(nil), do: "-"

  defp fmt(dt) do
    dt
    |> DateTime.shift_zone!(@tz, Breakline.time_zone_database())
    |> Calendar.strftime("%a %H:%M")
  end

  defp at(h, m) do
    Fake.set_now(local(h, m))
    Enforcer.evaluate()
    IO.puts(dim("  -- clock #{fmt(Fake.now())} --"))
  end

  # tallies for the summary
  defp tally(key), do: Process.put(key, (Process.get(key) || 0) + 1)
  defp count(key), do: Process.get(key) || 0

  # what the real gateway says. the gateway lines come from Enforcer.status, the fake
  # firewall's applied state and the resolver's own events

  defp lookup(who, port, name, expect) do
    seen = length(Events.recent(10_000))
    say(who, "looks up #{name}")
    reply = FakeUpstream.query(port, name)
    ips = for {:a, ip} <- FakeUpstream.answers(reply), do: :inet.ntoa(ip)
    event = Events.recent(10_000) |> Enum.drop(seen) |> List.last()
    allowed? = FakeUpstream.rcode(reply) == 0 and ips != []

    text =
      if allowed?,
        do: "answered #{Enum.join(ips, ", ")}",
        else: "NXDOMAIN (#{event[:type]} #{event[:match]}, #{event[:channel]} channel)"

    say(:gateway, "dns: " <> verdict(text, allowed?))
    if allowed? != (expect == :allowed), do: raise("expected #{expect} for #{name}: #{text}")
    tally({who, expect})
    pause()
  end

  defp firewall do
    # the resolved ips reach the firewall from a background lookup
    Process.sleep(60)
    %{state: %{desired: d, resolved: resolved}} = Gateway.Firewall.snapshot()
    ports = Enum.map_join(d.exclusive_ports, ", ", &"#{&1.port}/#{&1.proto}")

    text =
      if d.locked?,
        do: verdict("LOCKED", false) <> " (#{d.mode}), drops #{map_size(resolved)} ips, #{ports}",
        else: verdict("OPEN", true) <> ", kernel guard re-locks at #{fmt(d.locks_at)}"

    say(:gateway, "firewall: " <> text)

    pause(300)
  end

  defp why({:locked, :default}), do: "no window or approval"
  defp why({:locked, :no_policy}), do: "no policy yet"
  defp why({:locked, {:advisory_lock, l}}), do: "advisory lock #{l.source}"
  defp why({:open, {:window, id, {_, e}}}), do: "window #{id} until #{fmt(e)}"

  defp why({:open, {:break_glass, bg}}), do: "approved by #{bg.approved_by} to #{fmt(bg.until)}"

  defp state do
    s = Enforcer.status()
    version = if s.policy_version, do: "v#{s.policy_version}, ", else: ""
    text = verdict("#{String.upcase("#{s.state}")} (#{why(s.reason)})", s.state == :open)
    say(:gateway, "state: #{text}, #{version}next change #{fmt(s.next_change)}")

    # the pure layer must agree with the enforcer
    if s.policy_version do
      {:ok, p} = Policy.new(Map.put(Sim.Cloud.current(), :version, s.policy_version))
      if Schedule.state_at(p, Fake.now()) != s.state, do: raise("schedule and enforcer disagree")
    end

    firewall()
  end

  # the cloud signs, the gateway verifies and applies. returns the signed wire map
  defp publish(change, label, ttl \\ 600) do
    {version, wire} = Sim.Cloud.publish(change, ttl)
    say(:cloud, "signs policy v#{version} (#{label}), ed25519, valid #{div(ttl, 60)} min")

    :ok = Enforcer.submit(wire)
    say(:gateway, "verified signature, site, expiry and version; applied v#{version}")
    state()
    wire
  end

  defp reject(wire, expected) do
    if Enforcer.submit(wire) != {:error, expected}, do: raise("expected #{expected}")
    tally(:rejected)
    say(:gateway, "command: " <> verdict("REJECTED #{expected}", false))
    pause()
  end

  defp story(port, dir) do
    anydesk = "boot.net.anydesk.com"
    relay = "relay-7f3a.net.anydesk.com"
    IO.puts(paint("Breakline: one Monday at Bayside Physio (MSP Harbour IT, tool AnyDesk)", "1"))

    header(1, "Setup: locked by default")
    at(9, 0)
    state()
    say(:msp, "onboards Bayside Physio: AnyDesk, enforce mode, standing window Sun 02:00-04:00")
    pause()
    publish(%{}, "initial policy")

    header(2, "A normal morning at the clinic")
    at(9, 5)
    lookup(:clinic, port, "app.cliniko.com", :allowed)
    lookup(:clinic, port, anydesk, :blocked)
    firewall()

    header(3, "Harbour IT books a window")
    at(13, 50)
    say(:msp, "books today 14:00-14:30 to fix the reception printer")
    pause()

    window = %{
      id: "printer",
      starts_at: ~N[2026-11-02 14:00:00],
      ends_at: ~N[2026-11-02 14:30:00]
    }

    # valid for an hour, so the attacker's replay later is stale rather than merely expired
    booking = publish(%{one_off_windows: [window]}, "window 14:00-14:30", 3600)
    lookup(:msp, port, anydesk, :blocked)
    at(14, 0)
    say(:gateway, "the window starts")
    state()
    lookup(:msp, port, anydesk, :allowed)
    at(14, 30)
    say(:gateway, "the window ends")
    state()
    lookup(:msp, port, anydesk, :blocked)

    header(4, "The attacker, with stolen RMM credentials")
    at(14, 40)
    say(:attacker, "holds a stolen Harbour IT login and wants the reception PC")
    lookup(:attacker, port, relay, :blocked)
    say(:attacker, "forges an \"open until 23:59\" command, signed with their own key")
    {_, other_priv} = Command.generate_keypair()
    glass = %{until: local(23, 59), approved_by: "harbour-it-admin"}
    site = Map.put(Sim.Cloud.current(), :break_glass, glass)
    reject(Sim.Cloud.sign(other_priv, Sim.Cloud.key_id(), 99, site, 3600), :bad_signature)
    say(:attacker, "replays the captured 14:00 window command (genuine signature, in date)")
    reject(Command.encode_wire(booking), :stale_version)
    lookup(:attacker, port, relay, :blocked)

    header(5, "AnyDesk lands on the CISA KEV list")
    at(16, 0)
    say(:clinic, "manager Dana approves an hour for a software update (open until 17:00)")
    pause()
    publish(%{break_glass: %{until: local(17, 0), approved_by: "Dana"}}, "break-glass")
    lookup(:msp, port, anydesk, :allowed)
    at(16, 20)
    say(:cloud, "feed poll: new KEV entry #{@kev["cveID"]}, #{@kev["vulnerabilityName"]}")
    matched = Catalog.kev_match(@kev)

    say(
      :cloud,
      "catalog match: vendor #{@kev["vendorProject"]}, product #{@kev["product"]} -> #{Enum.join(matched, ", ")}"
    )

    true = matched == ["anydesk"] and "anydesk" in Sim.Cloud.current().tool_ids
    say(:cloud, "Bayside Physio uses it: emergency lock, no expiry")
    pause()

    lock = %{
      id: "kev-#{@kev["cveID"]}",
      source: "kev:#{@kev["cveID"]}",
      reason: "CISA KEV #{@kev["cveID"]}: #{@kev["vulnerabilityName"]}",
      expires_at: nil
    }

    publish(%{advisory_locks: [lock]}, "emergency lock")
    say(:gateway, "Dana's approval is still in the policy, but the lock outranks it")
    lookup(:msp, port, anydesk, :blocked)
    lookup(:attacker, port, relay, :blocked)

    header(6, "Patch, then lift the lock")
    at(16, 50)
    say(:msp, "patches AnyDesk on the clinic PCs, then lifts the lock")
    say(:cloud, "passkey step-up passed for the Harbour IT admin")
    pause()
    publish(%{advisory_locks: []}, "lock lifted")
    lookup(:msp, port, anydesk, :allowed)
    at(17, 0)
    say(:gateway, "Dana's hour ends")
    state()
    lookup(:msp, port, anydesk, :blocked)

    header(7, "The audit trail")
    audit(dir)

    header(8, "Who saw what")

    {open, shut} = {count({:msp, :allowed}), count({:msp, :blocked})}
    say(:msp, "AnyDesk opened #{open}x, only by window or approval; refused #{shut}x otherwise.")
    say(:clinic, "browsing untouched; AnyDesk shut by default, and at once when it hit KEV.")
    {refused, rejected} = {count({:attacker, :blocked}), count(:rejected)}
    say(:attacker, "#{refused} lookups refused, #{rejected} commands rejected, edit caught.")
  end

  defp audit(dir) do
    path = Path.join(dir, "audit.jsonl")
    {:ok, records} = Store.read_audit(path)
    say(:gateway, "audit chain: #{length(records)} entries, each hashed over the one before")

    for %{"seq" => seq, "hash" => hash, "entry" => e} <- records do
      detail =
        case e["type"] do
          "state_changed" -> "#{e["state"]} (#{e["reason"]["rule"]})"
          "policy_applied" -> "v#{e["policy_version"]} key #{e["key_id"]}"
          "command_rejected" -> e["reason"]
          _ -> ""
        end

      line = "#{String.pad_leading("#{seq}", 2)} #{String.slice(hash, 0, 8)}  "
      IO.puts("           " <> line <> String.pad_trailing(e["type"], 17) <> detail)
    end

    pause(900)
    :ok = AuditLog.verify_chain(records)
    say(:cloud, "verifies the chain: " <> verdict("OK", true))

    # someone with disk access rewrites the log so the emergency lock never happened
    say(:attacker, "edits the log: the emergency lock becomes a plain \"default\" lock")
    original = File.read!(path)
    lock_rule = ~s("rule":"advisory_lock")
    forged = String.replace(original, lock_rule, ~s("rule":"default"), global: false)

    if forged == original, do: raise("nothing to tamper with")
    File.write!(path <> ".tampered", forged)

    case Store.read_audit(path <> ".tampered") do
      {:error, {:broken_at, seq, reason}} ->
        broken = verdict("BROKEN at entry #{seq} (#{reason})", false)
        say(:cloud, "verifies the chain: " <> broken)

      other ->
        raise "tampering went unnoticed: #{inspect(other)}"
    end
  end
end

Sim.run()
