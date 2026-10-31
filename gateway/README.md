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
notices and applies the desired state again. Should the uplink crash more than 10 times
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

Dev uses the inbox. To connect to a local cloud on port 4011, uncomment the
`config :gateway, :uplink` block in `config/dev.exs`; it expects
`priv/keys/gateway_cert.pem`, `gateway_key.pem` and `ca_cert.pem` (git-ignored). Then:

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

## Tests

```sh
mix test                      # everything except real nftables
mix test --only nft_docker    # golden rulesets loaded into nft in a throwaway container
```

The test config starts no children. Tests start what they need, including the whole
tree through `Gateway.Application.children/1`.

## Production config

`config/runtime.exs` reads the following environment variables when `MIX_ENV=prod`:

- `BREAKLINE_SITE_ID`
- `BREAKLINE_PUBLIC_KEYS` (`key_id=base64url,...`)
- `BREAKLINE_LAN_INTERFACES` (`eth1,...`)
- `BREAKLINE_UPSTREAMS` (optional, `1.1.1.1,9.9.9.9:53,[2606:4700:4700::1111]:53`)
- `BREAKLINE_DATA_DIR` (default `/data/breakline`)
- `BREAKLINE_DEFAULT_MODE` (`monitor` or `enforce`)
- `BREAKLINE_DNS_IP` (default `0.0.0.0`)
- `BREAKLINE_UPLINK_URL` (optional, `wss://...`; without it there is no uplink), and
  with it `BREAKLINE_UPLINK_CERT`, `BREAKLINE_UPLINK_KEY`, `BREAKLINE_UPLINK_CA` (pem
  paths) and optionally `BREAKLINE_UPLINK_SERVER_NAME` (the name the server certificate
  must carry, when it is not the url's host)

In prod the firewall is `NftImpl` and DNS listens on port 53.
