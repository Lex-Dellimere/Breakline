# gateway

The Breakline site gateway: a DNS resolver, a firewall and the Enforcer that keeps the
MSP's RMM channel closed unless the client's signed policy says it is open right now.

## Supervision tree

`Gateway.Supervisor` (one_for_one), one subtree per concern, in start order:

1. `:firewall`: `Gateway.Firewall.Server` with the configured impl (`FakeImpl` in dev,
   `NftImpl` in prod)
2. `Gateway.Events`: in-memory ring buffer of DNS and enforcer events
3. `:enforcer` (rest_for_one): `Gateway.Store` (disk state), then `Gateway.Enforcer`
4. `Gateway.DNS.Supervisor`: the resolver. Resolved RMM ips go to the firewall, events
   go to `Gateway.Events`
5. `Gateway.Dev.Inbox`: dev only, a polled directory of signed policies
6. `:uplink`: `Gateway.Uplink.Keeper`, which runs `Gateway.Uplink.Supervisor` with
   `Gateway.Uplink` under it, only when `config :gateway, :uplink` is set

A DNS crash never touches the firewall. When the firewall server restarts, the enforcer
notices and applies the desired state again. It does the same when the table is gone
(a `flush ruleset`, say from a restart of `nftables.service`), at its next evaluation,
within 15 s. Should the uplink crash more than 10 times
a minute, its supervisor gives up and the keeper starts it again after a cool-off
(5 minutes, `cool_off_ms` in the uplink config). Each cool-off is logged at error level
and counted in `Gateway.Uplink.status/0` (`cool_offs`). The keeper never crashes, so
the crash loop never reaches the other subtrees, and the gateway keeps enforcing
throughout.

## Uplink

`Gateway.Uplink` is the gateway's only link to the cloud. It dials out (a websocket to
Phoenix Channels, `slipstream`, mutual TLS) and the gateway never listens for the
cloud. It joins `gateway:<site_id>`, takes signed policies pushed by the cloud (handed
to the Enforcer, answered with `policy_result`), and sends a heartbeat with the
enforcer status, batches of events and the audit chain after the cloud's last ack.
The protocol is in the module doc.

Offline, nothing changes for enforcement: the uplink logs and reconnects with
exponential backoff (1 s to 60 s, with jitter).

Dev uses the inbox until the cloud's dev certificates exist. Running
`mix cloud.dev.gateway_cert <site_id>` in `cloud/` writes `priv/keys/gateway_cert.pem`,
`gateway_key.pem`, `ca_cert.pem`, `site.json` and `cloud_signer.public.json` here
(all git-ignored). When all five are present, `config/dev.exs` turns the uplink on
automatically (`wss://localhost:4011/gateway/socket/websocket`), takes the site id from
`site.json`, trusts the cloud's signing key, and keeps its state in `tmp/dev_uplink/`.
The full walkthrough is "End-to-end demo" in `cloud/README.md`. Then:

```sh
elixir --sname probe --rpc-eval breakline_gw@Nx 'IO.inspect Gateway.Uplink.status()'
```

shows `connected?`, `joined?`, `last_heartbeat_at`, `events_in_flight` and
`audit_ack`.

## Dev demo

Everything runs on a normal Linux host. There is no root and no `nft`: the firewall is
the in-memory `FakeImpl`, and the resolver listens on `127.0.0.1:5300` and forwards to
1.1.1.1 / 9.9.9.9. State lives in `gateway/tmp/dev/` (git-ignored). The site id is
`dev-site`.

All commands run from `gateway/`.

### 1. Generate the dev signing key (once)

```sh
mix gateway.dev.keygen
```

This writes `priv/keys/dev_ed25519.json` (git-ignored, mode 0600) and prints the key id
and public key. The dev config trusts that public key. Run it before starting the
gateway, or restart the gateway afterwards.

### 2. Start the gateway

```sh
elixir --sname breakline_gw -S mix run --no-halt
```

You can also use `iex --sname breakline_gw -S mix` to get a shell in the same node. The
`--sname` is only needed to query the node from another terminal (step 5). On a fresh
start the log shows:

```
[info] dev inbox watching .../gateway/tmp/dev/inbox
[info] state locked (no_policy), mode monitor, clock_synced true, policy nil
```

With no policy the gateway is locked but in the default `:monitor` mode. Catalog names
still resolve, and each lookup is logged as a would-block event.

### 3. Lock: sign a policy into the inbox

In a second terminal:

```sh
mix gateway.dev.sign priv/dev/examples/locked.exs
dig @127.0.0.1 -p 5300 boot.net.anydesk.com
```

The inbox picks the file up within 2 s and moves it to `tmp/dev/inbox/processed/`.
The gateway logs `state locked (default), mode enforce`, and `dig` now gets
`status: NXDOMAIN`. The resolver still looks the name up in the background, so the
fake firewall's resolved set fills with AnyDesk's relay ips.

### 4. Open: sign a one-off window around now

```sh
mix gateway.dev.sign priv/dev/examples/open_now.exs
dig @127.0.0.1 -p 5300 boot.net.anydesk.com
```

The window is computed when you sign: Sydney time, from 5 minutes ago to 30 minutes from
now. The gateway logs `state open (window)` and `dig` returns the A records. The window
closes on its own when it ends: the enforcer wakes at the schedule's next change.

`priv/dev/examples/monitor.exs` is the pilot setting: monitor mode with a weekly window.

Options: `--version N` (defaults to the current unix time, so each run is newer than
the last), `--ttl S` (how long the command can be accepted, default 3600, max 86400),
`--out PATH` (instead of the inbox). A `.json` file in `Breakline.Policy.to_map/1` form
works too.

A replay is rejected. Copy an applied file back into the inbox:

```sh
cp tmp/dev/inbox/processed/locked-*.json tmp/dev/inbox/replay.json
```

It is logged as `inbox: rejected replay.json: :stale_version` and moved to
`rejected/`.

### 5. Look at the state

From an `iex` shell in the node, or from another terminal through `--rpc-eval` (replace
`Nx` with `hostname -s`):

```sh
elixir --sname probe --rpc-eval breakline_gw@Nx 'IO.inspect Gateway.Enforcer.status()'
elixir --sname probe --rpc-eval breakline_gw@Nx 'IO.inspect Gateway.Firewall.snapshot()'
elixir --sname probe --rpc-eval breakline_gw@Nx 'IO.inspect Gateway.Events.recent(10)'
```

- `Gateway.Enforcer.status/0`: state, reason, policy version, mode, clock sync, next
  change, last apply, and a firewall summary.
- `Gateway.Firewall.snapshot/0`: the desired state the FakeImpl last applied
  (`locked?`, `mode`, `block_cidrs`, `exclusive_ports`, `doh_ips`) and the resolved
  RMM ips with their tool and expiry.
- `Gateway.Events.recent/1`: the latest blocked, would-block, state-changed and
  policy events.

On disk in `tmp/dev/`:
- `command.json`: the last accepted signed command, byte for byte.
- `verifier.json`: the last version and the nonces seen.
- `audit.jsonl`: the hash-chained audit log. Check it with
  `Gateway.Store.read_audit("tmp/dev/audit.jsonl")`.

Restart the gateway and it comes back with the same policy. To start over, stop it and
`rm -rf tmp/dev`.

## Simulation

A narrated, one-command run of the whole story: a clinic, its MSP and an attacker, a
booked window, a CISA KEV emergency lock and the audit trail. It drives the real
enforcer, resolver, fake firewall and `core` (signed commands, schedule, catalog, audit
chain); the cloud, the people, the upstream dns and the clock are simulated.

```sh
mix run --no-start sim/breakline_sim.exs
```

`--no-start` keeps the dev tree (port 5300, the inbox) from booting, so it is safe next
to a running dev gateway. It needs no cloud, root or `nft`, and takes about 25 s;
`SIM_FAST=1` skips the pauses and `NO_COLOR=1` turns colours off (they are also off when
piped). Source: `sim/breakline_sim.exs`.

### Attack demo

A red team run with real packets, not the in-process fake: a compromised MSP account and
a hostile internet against the prod release in a throwaway `debian:trixie-slim`
container (real nftables, a client namespace as the clinic pc, an upstream namespace as
the internet; never host networking). The attacker resolves AnyDesk's relay, dials relay
ips and ports with no dns, bypasses the resolver via 8.8.8.8, tries DNS-over-HTTPS, rides
a booked window until a KEV lock cuts the session, and pushes forged and replayed
commands. It ends on two honest gaps (a hardcoded relay ip on 443, an uncatalogued tool
such as RustDesk; threat model T1 and T2) and a scoreboard of attack, result and verdict
(BLOCKED, ALLOWED, GAP). A beat that does not behave as documented fails the run.

```sh
mix run --no-start sim/attack.exs
```

It needs docker and takes about a minute once the release is built (the first run builds
it); `SIM_FAST=1` and `NO_COLOR=1` work as above. It reuses the helpers behind
`mix test --only traffic`. Source: `sim/attack.exs`.

## Tests

```sh
mix test                      # everything except real nftables
mix test --only nft_docker    # golden rulesets loaded into nft in a throwaway container
mix test --only traffic       # real packets through the release, see "Traffic tests"
```

The test config starts no children. Tests start what they need, including the whole
tree through `Gateway.Application.children/1`.

## Production config

`config/runtime.exs` reads the following environment variables when `MIX_ENV=prod`:

- `BREAKLINE_SITE_ID`
- `BREAKLINE_PUBLIC_KEYS` (`key_id=base64url,...`)
- `BREAKLINE_LAN_INTERFACES` (`eth1,...`)
- `BREAKLINE_UPSTREAMS` (optional, `1.1.1.1,9.9.9.9:53,[2606:4700:4700::1111]:53`)
- `BREAKLINE_DATA_DIR` (default `/var/lib/breakline`)
- `BREAKLINE_DEFAULT_MODE` (`monitor` or `enforce`)
- `BREAKLINE_DNS_IP` (default `::`, which takes ipv4 and ipv6 clients; `0.0.0.0` on a
  host without ipv6, but then the ipv6 dns redirect finds nothing listening)
- `BREAKLINE_UPLINK_URL` (optional, `wss://...`; without it there is no uplink), and
  with it `BREAKLINE_UPLINK_CERT`, `BREAKLINE_UPLINK_KEY`, `BREAKLINE_UPLINK_CA` (pem
  paths) and optionally `BREAKLINE_UPLINK_SERVER_NAME` (the name the server certificate
  must carry, when it is not the url's host)

In prod the firewall is `NftImpl` and DNS listens on port 53.

## Release and pilot box

The pilot box is Debian 13 amd64 running the release as a hardened systemd service. The
runbook for whoever installs one is `docs/PILOT.md`.

```sh
mix gateway.package.deb                 # MIX_ENV=prod; writes _build/prod/breakline-gateway_<vsn>_amd64.deb
mix test --only deb_docker              # installs it in a debian:trixie-slim container and runs it
```

Build on Debian 13 amd64: the release bundles the build host's erts. The package sources
(unit, `/etc/default` file, the `breakline-gateway` wrapper, maintainer scripts and the
network examples for each install mode) are in `packaging/deb/`.

- **Distribution** is only there for `breakline-gateway status` (`bin/gateway rpc`). There
  is no epmd: the node is `gateway@127.0.0.1` and listens on 127.0.0.1:4370 only, and rpc
  clients connect without listening (`rel/vm.args.eex`, `rel/remote.vm.args.eex`).
- **Cookie:** the build-time cookie is removed from the package. `postinst` writes a
  per-box one to `/etc/breakline-gateway/cookie` (`breakline`, 0400), and `rel/env.sh.eex`
  reads it. Without it the release refuses to start.
- **Unit:** `User=breakline`, only `CAP_NET_ADMIN` (nft) and `CAP_NET_BIND_SERVICE` (:53),
  `ProtectSystem=strict`, a syscall filter and `MemoryDenyWriteExecute=yes`. The BEAM JIT
  dual-maps its code, so it runs under the kernel's `PR_SET_MDWE`. State is in
  `/var/lib/breakline` (`StateDirectory=`). `systemd-analyze security` scores it 1.6.
- **Wrapper:** `breakline-gateway status` and
  `breakline-gateway enroll <cloud_url> <code> --ca-sha256 <hex>`, both run as the
  `breakline` user.

## Enrolment

A box gets its site, the cloud's signing key and its uplink by enrolling, not from a
CA. An admin clicks **Enrol gateway** on the site page (after a passkey prompt) and gets
a one-time code, valid 30 minutes, and the command to run on the box:

```sh
sudo breakline-gateway enroll https://gw.example.com:4011 ABCD-EFGH-...-WXYZ --ca-sha256 <hex>
```

The package wraps it as `bin/gateway eval 'Gateway.Enroll.run_from_env()'` with
`BREAKLINE_ENROLL_URL`, `BREAKLINE_ENROLL_CODE`, `BREAKLINE_ENROLL_CA_SHA256` and
`BREAKLINE_DATA_DIR`. It prints one line and exits 0 on success, 1 on failure.

`Gateway.Enroll` makes the box's identity once, an EC P-256 key and a self-signed
certificate, and keeps it. It connects to the url with that certificate, trusting the
server only through `--ca-sha256` (the sha256 of the CA certificate's
SubjectPublicKeyInfo, as kubeadm does) and the url's host name, and posts the code. The
cloud pins the certificate of that TLS session on the site. Files, under the data
directory (default `/var/lib/breakline`):

- `identity/gateway_cert.pem`, `identity/gateway_key.pem` (0600, directory 0700)
- `server_ca.pem`: the CA of the cloud's gateway endpoint, checked against the pin
- `enrollment.json`: site id, public keys, uplink url, server name, cloud url,
  fingerprint

At the next boot `config/runtime.exs` uses them for everything the `BREAKLINE_*`
variables do not set (leave `BREAKLINE_SITE_ID`, `BREAKLINE_PUBLIC_KEYS` and the
`BREAKLINE_UPLINK_*` variables unset on an enrolled box). With `BREAKLINE_SITE_ID` set,
the environment alone configures the gateway, as before. A box that is not enrolled
boots without raising: no site, no trusted key and no uplink, so it stays locked, and it
logs that it is not enrolled. `BREAKLINE_LAN_INTERFACES` is still needed to start it.

Enrolling again (a new code from the site page) keeps the identity; enrolling a new box
moves the site's pin to it, and the old box is disconnected and locked out.

In dev, against a local cloud (see "Gateway enrolment" in `cloud/README.md`):

```sh
mix gateway.enroll https://localhost:4011 <code> --ca-sha256 <hex>   # into tmp/dev_enrolled
elixir --sname gw -S mix run --no-halt
```

`config/dev.exs` prefers `tmp/dev_enrolled/enrollment.json` over the `priv/keys/`
shortcut; remove `tmp/dev_enrolled` to go back.

## Traffic tests

```sh
mix test --only traffic
```

Real packets through the prod release (`MIX_ENV=prod mix release`, which the suite
builds) in throwaway `debian:trixie-slim` containers: `--rm`, `--init`, NET_ADMIN and
SYS_ADMIN only, no host networking, nothing on the host changed. The scripts are in
`test/fixtures/traffic/`. Each container holds three network namespaces: `client`
(the LAN), the container itself (the gateway) and `upstream` (dnsmasq with catalog,
vanity and plain names on documentation addresses, a rogue resolver on 8.8.8.8, and
listeners on 80, 443, 853, 5938 and 6568). Three containers run in parallel:

- `router`: LAN and WAN on separate interfaces, the gateway forwards.
- `bridge`: `br0` with both veths, one subnet, `BREAKLINE_LAN_INTERFACES=br0`, and
  `net.bridge.bridge-nf-call-iptables` and `-ip6tables` at 1 through
  `docker run --sysctl` (`/proc/sys` is read-only inside the container).
- `bridge` with those sysctls at 0, to show what the gateway reports then.

The scenarios: the DNS redirect from any resolver address (udp and tcp, ipv4 and
ipv6), locked drops, an open window, sessions cut when a window ends or a lock
arrives, monitor counters, a killed and restarted beam, a window that ends while the
beam is down, a flushed ruleset, the WAN side of the resolver, and the bridge setups
the firewall reports.

An open state with a known end also loads the locked rules behind `meta time >= end`
(unix seconds; `nft list` shows them in local time), so the kernel closes the window
on time when the beam is not there to apply the lock. When it is, it swaps in the
plain locked rules at that instant, in one transaction.

Bridge mode needs br_netfilter loaded, both sysctls at 1, and the bridge (not a port)
as the LAN interface. Otherwise nothing on the bridge is enforced, and
`Gateway.Enforcer.status().firewall.host_problems` says why.

Not checked: the monitor-mode log lines. The kernel only logs from the init network
namespace unless `net.netfilter.nf_log_all_netns` is set, so the suite asserts on the
counters and on the `limit 30/minute burst 10` in the listed rules.
