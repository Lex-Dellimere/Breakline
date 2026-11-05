# a narrated red team run against the real gateway, with real packets.
#
#   cd gateway && mix run --no-start sim/attack.exs      (SIM_FAST=1 skips the pauses)
#
# real: the prod release (resolver, enforcer, nftables) in a throwaway debian container, a
# client namespace (the clinic pc, where the remote tool's agent dials out from) and an
# upstream namespace (the fake internet: dnsmasq, a rogue resolver on 8.8.8.8, listeners).
# the container is cut off from docker's network and removed at the end; nothing touches the
# host's networking. needs docker and builds the release if it must. the helpers are the
# ones behind `mix test --only traffic`.
# simulated: the cloud and the msp (this script signs with core, as the cloud does) and the
# attacker's stolen account, which is only a story: what matters is the traffic it causes.
# every beat runs. udp is left to the traffic suite: the upstream only logs datagrams, and a
# session here needs a tcp echo.

Code.require_file("../test/support/traffic.ex", __DIR__)

defmodule Attack.Out do
  @moduledoc false
  # same tags, colours and pauses as breakline_sim.exs

  @colours %{msp: 34, cloud: 35, gateway: 36, attacker: 31}
  @verdicts %{blocked: "1;32", allowed: "1;36", gap: "1;33"}

  def color?, do: System.get_env("NO_COLOR") in [nil, ""] and IO.ANSI.enabled?()
  def paint(text, code), do: if(color?(), do: "\e[#{code}m#{text}\e[0m", else: text)

  def say(who, text),
    do: IO.puts(paint(String.pad_trailing("[#{who}]", 11), @colours[who]) <> text)

  def verdict(v), do: paint(v |> Atom.to_string() |> String.upcase(), @verdicts[v])
  def dim(text), do: paint(text, "2")

  def header(n, title) do
    pause(900)
    IO.puts("\n" <> paint("#{n}. #{title}", "1"))
  end

  def pause(ms \\ 650), do: if(System.get_env("SIM_FAST") in [nil, ""], do: Process.sleep(ms))
end

defmodule Attack do
  @moduledoc false

  alias Breakline.{Command, Policy}
  alias Gateway.Traffic, as: T
  import Attack.Out

  # dnsmasq in upstream answers these, see test/fixtures/traffic/topology.sh
  @lan_dns "10.10.0.1"
  @boot "boot.net.anydesk.com"
  @boot_ip "198.51.100.10"
  # a real relay address nobody ever resolved through the gateway
  @unseen_relay "198.51.100.11"
  @web "shop.example.test"
  @web_ip "203.0.113.80"
  @nowhere "192.0.2.50"
  @rustdesk "rd.selfhosted.test"
  @rustdesk_ip "192.0.2.77"
  # what the attacker's resolver on 8.8.8.8 says to everything
  @rogue_answer "192.0.2.66"
  @kev "CVE-2026-99001"

  def run do
    Logger.configure(level: :error)
    started = System.monotonic_time(:second)
    IO.puts(paint("Breakline red team: a stolen MSP account against a clinic's gateway", "1"))
    say(:attacker, "owns the MSP's RMM login and the internet. wants a session to the clinic pc")
    say(:gateway, "building the clinic: pc, gateway (prod release, real nftables), internet")
    ctx = T.start!(:router, on_exit: &Process.put(:cleanup, &1))

    try do
      T.lock!(ctx)
      say(:gateway, "policy: #{state(ctx)}, mode enforce, tool anydesk, no window booked")
      story(ctx)
      scoreboard()
    after
      if cleanup = Process.get(:cleanup), do: cleanup.()
    end

    IO.puts(dim("\n  took #{System.monotonic_time(:second) - started} s"))
  end

  defp story(ctx) do
    # these listeners are ours: the shared topology has none on 7070 or for rustdesk, and a
    # refused connection would look the same as a dropped one
    upstream_listen(ctx, [7070, 21116, 21117])

    header(1, "AnyDesk resolves its relay name")
    say(:attacker, "the agent on the clinic pc looks up #{@boot}")
    r = dig(ctx, @lan_dns, @boot)
    T.await_member(ctx, "rmm4", @boot_ip)
    say(:gateway, "it looked the name up itself: #{@boot_ip} is now in the rmm4 drop set")
    score("dns: resolve the relay name", dns_text(r), blocked?(r), :blocked)

    header(2, "no dns at all: straight to a relay ip and AnyDesk's ports")
    say(:attacker, "dials #{@boot_ip}:443, #{@nowhere}:6568 and #{@nowhere}:7070")
    specs = [{:tcp, @boot_ip, 443}, {:tcp, @nowhere, 6568}, {:tcp, @nowhere, 7070}]
    out = connect(ctx, [{:tcp, @web_ip, 443} | specs])
    dropped = Enum.count(specs, &(out[&1] == :drop))

    score(
      "direct to relay ip, ports 6568, 7070",
      "#{dropped} of 3 dropped",
      dropped == 3,
      :blocked
    )

    header(3, "skip the gateway's dns: ask a public resolver")

    say(
      :attacker,
      "8.8.8.8 is mine and answers #{@rogue_answer} to anything. ask it for #{@boot}"
    )

    rs = for tcp <- [false, true], do: dig(ctx, "8.8.8.8", @boot, tcp: tcp)
    control = dig(ctx, "8.8.8.8", @web)
    say(:gateway, "client :53 is redirected to the gateway, whatever address the packet carries")
    say(:gateway, "control, #{@web}: #{dns_text(control)}, so the rogue never saw it")
    score("dns via 8.8.8.8, udp and tcp", dns_text(hd(rs)), Enum.all?(rs, &blocked?/1), :blocked)

    header(4, "dns-over-https to a public resolver")
    say(:attacker, "resolve over https: dns.google, cloudflare-dns.com, or 1.1.1.1:443 itself")
    names = for n <- ["dns.google", "cloudflare-dns.com"], do: dig(ctx, @lan_dns, n)
    specs = [{:tcp, "1.1.1.1", 443}, {:tcp, "8.8.8.8", 443}, {:tcp, "1.1.1.1", 853}]
    out = connect(ctx, specs)
    held? = Enum.all?(names, &blocked?/1) and Enum.all?(specs, &(out[&1] == :drop))
    score("doh and dot: names and resolver ips", "names nxdomain, ips dropped", held?, :blocked)

    header(5, "the msp opens a window, then CISA puts AnyDesk on the KEV list")
    until = DateTime.add(DateTime.utc_now(), 600) |> DateTime.truncate(:second)
    bg = %{until: until, approved_by: "dana@harbour-it.example"}
    say(:msp, "dana approves a 10 minute break-glass for a real support call")

    say(
      :cloud,
      "signs a policy with break-glass until #{Calendar.strftime(until, "%H:%M:%S")} UTC"
    )

    open = T.submit!(ctx, break_glass: bg)
    window = File.read!(Path.join(ctx.dir, "policy-#{open.policy_version}.json"))
    guard? = JSON.encode!(T.forward_rules(ctx)) =~ ~s("time")

    say(
      :gateway,
      "state: #{state(ctx, open)}, lock rules kept behind a kernel time guard: #{guard?}"
    )

    r = dig(ctx, @lan_dns, @boot)
    out = connect(ctx, [{:tcp, @boot_ip, 443}, {:tcp, @nowhere, 6568}, {:tcp, @nowhere, 7070}])
    open? = r.answers == [@boot_ip] and Enum.all?(out, &(elem(&1, 1) == :pass))
    score("session inside the window", "resolves, all ports connect", not open?, :allowed)

    session = T.start_session!(ctx, @boot_ip, 443)

    say(
      :attacker,
      "session up on #{@boot_ip}:443, #{length(T.session(ctx, session))} echoes so far"
    )

    say(
      :cloud,
      "CISA KEV lists AnyDesk (#{@kev}): signs an advisory lock, break-glass still in force"
    )

    lock = %{id: "kev-#{@kev}", reason: "AnyDesk is exploited", source: "kev:#{@kev}"}
    sent = T.now()
    locked = T.submit!(ctx, break_glass: bg, advisory_locks: [lock])
    say(:gateway, "state: #{state(ctx, locked)}, the lock beats the approval")
    last = T.await_cut(ctx, session)
    T.stop_session(ctx, session)
    cut = Float.round(last - sent, 1)

    say(
      :attacker,
      "session frozen: last echo #{cut} s after the push, #{length(T.session(ctx, session))} in all"
    )

    r = dig(ctx, @lan_dns, @boot)
    out = connect(ctx, [{:tcp, @boot_ip, 443}, {:tcp, @nowhere, 6568}])
    held? = last < sent + 3 and blocked?(r) and Enum.all?(out, &(elem(&1, 1) == :drop))

    score(
      "kev lock during a session",
      "cut #{cut} s after, new connects dropped",
      held?,
      :blocked
    )

    header(6, "forged and replayed commands")
    say(:attacker, "pushes policies that open the channel and switch enforcement to monitor")

    results =
      for {label, wire} <- [
            {"own key, claiming the cloud's key id", forge(ctx, "traffic")},
            {"own key, own key id", forge(ctx, "attacker-key")},
            {"the captured window command, replayed", window}
          ] do
        res = submit(ctx, wire)
        say(:gateway, "#{label}: #{inspect(res)}")
        res
      end

    now = T.status(ctx)
    say(:gateway, "state after: #{state(ctx, now)}, mode #{now.mode}")

    held? =
      Enum.all?(results, &match?({:error, _}, &1)) and now.state == :locked and
        now.mode == :enforce

    score("forged and replayed commands", "3 of 3 rejected, still locked", held?, :blocked)

    header(7, "what Breakline does not stop (threat model T1, T2)")

    say(
      :attacker,
      "my build has the relay ip hardcoded, so there is no dns: #{@unseen_relay}:443"
    )

    say(
      :gateway,
      "rmm4 holds #{inspect(T.set_members(ctx, "rmm4"))}: #{@unseen_relay} was never resolved here"
    )

    spec = {:tcp, @unseen_relay, 443}
    out = connect(ctx, [spec])
    say(:gateway, "443 is shared with the web, so only ips the gateway has seen are dropped")

    score(
      "hardcoded relay ip on 443, unresolved",
      "handshake #{out[spec]}",
      out[spec] == :drop,
      :gap
    )

    say(:attacker, "new plan: self-hosted RustDesk on #{@rustdesk}, ports 21116 and 21117")
    r = dig(ctx, @lan_dns, @rustdesk)
    out = connect(ctx, [{:tcp, @rustdesk_ip, 21116}, {:tcp, @rustdesk_ip, 21117}])
    echo = T.start_session!(ctx, @rustdesk_ip, 21117)

    say(
      :attacker,
      "relay session up: #{length(T.session(ctx, echo))} echoes. the site is #{state(ctx)}"
    )

    T.stop_session(ctx, echo)
    open? = r.answers == [@rustdesk_ip] and Enum.all?(out, &(elem(&1, 1) == :pass))

    score(
      "tool not in the catalogue (RustDesk)",
      "resolves, connects, session up",
      not open?,
      :gap
    )
  end

  ## what the attacker does and the gateway says

  # one dns query. the gateway line quotes the resolver's own event for it, when there is one
  defp dig(ctx, server, name, opts \\ []) do
    via = if opts[:tcp], do: " over tcp", else: ""
    if server != @lan_dns, do: say(:attacker, "asks #{server}#{via} for #{name}")
    seen = length(events(ctx))
    r = T.dig(ctx, server, name, opts)
    event = ctx |> events() |> Enum.drop(seen) |> Enum.find(&(&1[:qname] == name))
    tag = if event, do: " (event #{event.type}, #{inspect(event.match)})", else: ""
    say(:gateway, "dns: #{dns_text(r)}#{tag}")
    r
  end

  defp events(ctx), do: T.rpc!(ctx, "Gateway.Events.recent(5000)")

  defp connect(ctx, specs) do
    out = T.probe(ctx, specs)
    list = Enum.map_join(specs, ", ", &"#{elem(&1, 1)}:#{elem(&1, 2)} #{out[&1]}")
    say(:gateway, "handshakes: #{list}")
    out
  end

  defp dns_text(%{status: :noerror, answers: a}), do: "answered #{Enum.join(a, ", ")}"
  defp dns_text(%{status: status}), do: String.upcase("#{status}")
  defp blocked?(%{status: :nxdomain, answers: []}), do: true
  defp blocked?(_), do: false

  defp state(ctx, status \\ nil) do
    s = status || T.status(ctx)
    paint(String.upcase("#{s.state}"), if(s.state == :open, do: "1;31", else: "1;32"))
  end

  defp upstream_listen(ctx, ports) do
    for p <- ports do
      args = ["exec", "-d", ctx.cid, "/run/bl/in", "upstream", "ncat", "-lk", "-e", "/bin/cat"]
      {_, 0} = System.cmd("docker", args ++ ["#{p}"])
    end

    for p <- ports do
      check = ["/run/bl/in", "upstream", "ncat", "-z", "-w", "1", "127.0.0.1", "#{p}"]
      T.await(fn -> match?({_, 0}, T.exec(ctx, check)) end, 10_000, "listener #{p}")
    end
  end

  # a policy command signed with a key the gateway has never heard of
  defp forge(ctx, key_id) do
    {_pub, priv} = Command.generate_keypair()
    site = ctx.env["BREAKLINE_SITE_ID"]
    version = System.os_time(:microsecond) + 10_000_000
    forever = DateTime.add(DateTime.utc_now(), 86_400) |> DateTime.truncate(:second)

    {:ok, policy} =
      Policy.new(
        site_id: site,
        version: version,
        mode: :monitor,
        time_zone: "Australia/Sydney",
        tool_ids: ["anydesk"],
        break_glass: %{until: forever, approved_by: "msp-admin"}
      )

    [type: "policy", site_id: site, policy_version: version, ttl_seconds: 600]
    |> Keyword.put(:payload, Policy.to_map(policy))
    |> Command.new!()
    |> Command.sign(key_id, priv)
    |> Command.encode_wire()
  end

  # the entry point the uplink and the inbox both feed
  defp submit(ctx, json) do
    name = "attack-#{System.unique_integer([:positive])}.json"
    File.write!(Path.join(ctx.dir, name), json)
    T.rpc!(ctx, ~s|Gateway.Enforcer.submit(File.read!("/policies/#{name}"))|)
  end

  ## scoreboard

  # `held?` is whether the gateway stopped the attack, `expected` what the docs claim. any
  # other combination raises, so a regression (or a faked block) ends the run non-zero
  defp score(attack, result, held?, expected) do
    v =
      case {expected, held?} do
        {:blocked, true} -> :blocked
        {:allowed, false} -> :allowed
        {:gap, false} -> :gap
        other -> raise "#{attack}: not as documented (#{inspect(other)}): #{result}"
      end

    say(:gateway, "verdict: " <> verdict(v))
    Process.put(:rows, Process.get(:rows, []) ++ [{attack, result, v}])
    pause()
  end

  defp scoreboard do
    rows = Process.get(:rows)
    w = fn i -> rows |> Enum.map(&String.length(elem(&1, i))) |> Enum.max() end
    pad = fn text, i -> String.pad_trailing(text, w.(i)) end
    IO.puts("\n" <> paint("Scoreboard", "1"))
    IO.puts(dim("  #{pad.("attack", 0)}  #{pad.("result", 1)}  verdict"))
    for {a, r, v} <- rows, do: IO.puts("  #{pad.(a, 0)}  #{pad.(r, 1)}  #{verdict(v)}")
    n = fn v -> Enum.count(rows, &(elem(&1, 2) == v)) end
    gaps = "known gaps (docs/THREAT_MODEL.md T1, T2)"

    IO.puts(
      "\n  #{n.(:blocked)} blocked, #{n.(:allowed)} allowed as designed, #{n.(:gap)} #{gaps}"
    )
  end
end

Attack.run()
