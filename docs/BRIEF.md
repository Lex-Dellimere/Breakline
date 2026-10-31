# Breakline — v1 build brief

> Saved verbatim from the original brief on 2026-10-31. The brief as received ends mid-sentence
> at "behind a `Signer`"; anything after that point is missing.
> Later decisions that change parts of this brief are in `DECISIONS.md`.

## Context
Breakline is a client-owned site gateway that keeps a business's MSP remote-access
channel (RMM / remote-control tools) **closed unless a window is booked or the client
approves**, and **auto-closes it** when that tool is under active exploitation
(CISA KEV / ACSC). Target: Australian mid-sized, site-heavy businesses (clinics,
manufacturing, logistics) that use an MSP.

Why: in Aug–Sep 2026, N-able N-central was actively exploited in Australia. Attackers
took over RMM servers and used the RMM's own remote-control feature to reach client
machines. Clients had no independent off-switch.

Demand is NOT yet validated. v1 exists to (a) demo in customer interviews and
(b) run monitor-only pilots. Optimise for a working, demo-able slice, not completeness.

## Working rules
- Planning, architecture decisions and reviews: Opus, high effort. Coding subagents:
  Opus, medium effort. Lookups/research (lib docs, feed formats): Haiku or Sonnet.
- Propose a plan before each phase; small commits; `mix test` green before moving on.
- Ask before adding a dependency not listed here. Verify every lib/feed URL before use.
- Never commit secrets or keys. Dev keys are generated locally and git-ignored.

## Non-goals (v1)
- No Windows/macOS endpoint agent (an RMM running as SYSTEM can kill it; gateway first).
- No mass-push/behavioural detection (needs the agent).
- No rogue-RMM inventory (Huntress RMM Guard already does this).
- No off-site laptop coverage; no TLS SNI inspection (P1); no MSP partner portal.

## Architecture (poncho layout, Elixir everywhere)
```
breakline/
  CLAUDE.md
  core/      # pure Elixir lib: policy, schedule, catalog, signed commands, audit chain
  cloud/     # Phoenix + LiveView + Ecto/Postgres + Oban
  gateway/   # OTP app: DNS resolver, firewall, uplink. Runs on host (dev) and Nerves
  firmware/  # Nerves project wrapping gateway (x86_64 mini PC, 2 NICs)
  docs/      # DECISIONS.md (log every decision + why), THREAT_MODEL.md
```

### core
- `Breakline.Policy`: site_id, version (monotonic), mode (`:enforce | :monitor`),
  tool_ids, recurring windows + one-off windows (stored in site IANA tz),
  advisory_locks (reason, source, expires_at), break_glass (until).
- `Breakline.Schedule.state_at(policy, utc_datetime) :: :open | :locked` — pure.
  Precedence: advisory lock > break-glass > window > default locked.
  Property-test with StreamData, including Australian DST transitions (Sydney, Adelaide;
  Brisbane has none). Use the `tz` library.
- `Breakline.Catalog`: tool_id → domains, CIDRs, ports, KEV vendor/product match keys.
  Seed from the LOLRMM project (check its licence and data format first).
  Start with: N-central/Take Control, ScreenConnect, NinjaOne, Datto RMM, AnyDesk,
  TeamViewer, Splashtop. Self-hosted RMM servers are added per site as host/IP.
- `Breakline.Command`: signed envelope {type, site_id, policy_version, issued_at,
  expires_at, nonce, payload} + Ed25519 signature via `:crypto`. Verify: signature,
  site_id, version > last applied, not expired, nonce unseen.
- `Breakline.AuditLog`: hash chain, hash = SHA-256(prev_hash <> canonical JSON(entry)).
  `verify_chain/1` detects any edit, insert or deletion.

### gateway
- `Gateway.DNS`: resolver on :53 (UDP+TCP), forwards upstream. For catalog domains:
  when locked → NXDOMAIN + event; when open → resolve normally. Record every resolved
  RMM IP into the firewall block set (with TTL). Use `:inet_dns` or a hex DNS lib.
- `Gateway.Firewall` behaviour with `NftImpl` (nftables, `nft -j`) and `FakeImpl`
  (tests). Rules: DNAT all client :53 to the gateway; drop :853 (DoT) and a list of
  known DoH endpoints; when locked, drop traffic to the RMM IP set + static CIDRs +
  per-site self-hosted RMM hosts. `:monitor` mode logs would-blocks only.
- `Gateway.Uplink`: outbound-only websocket to cloud (Phoenix Channels via
  `slipstream`), mTLS. Receives signed policies; sends heartbeat, events, audit entries.
  No inbound ports on the gateway, ever.
- `Gateway.Enforcer` (GenServer): applies policy, re-evaluates `Schedule` every 15 s
  and on policy change. Persists last good policy to disk; keeps enforcing offline.
  If the clock is unsynced → treat RMM as locked (fail closed for RMM only).
- Supervision: one supervisor per concern; crash of DNS must not drop firewall state.

### cloud
- Accounts: `phx.gen.auth` + passkeys (`wax_`) for client approvers; TOTP fallback
  (`nimble_totp`). Entities: tenant, site, approver, msp_contact, policy, event.
- Window booking: MSP contact gets a magic link (no account) to request a window →
  client approver approves with passkey → policy version bump → signed push to gateway.
- Break-glass: approver opens access now for N minutes (passkey required).
- Notifications: Teams/Slack webhooks + SMS. Messages contain a link only, never an
  approve button (a phished message must not be able to unlock).
- Advisories: Oban cron polls the CISA KEV JSON feed every 30 min (+ ACSC alerts feed;
  verify URL). Match against catalog → create advisory lock per site (per-tenant
  setting: auto-lock or ask) → notify.
- LiveView dashboard: site state (open/locked + why), upcoming windows, event timeline,
  audit export (JSON + PDF) with chain verification result.
- Signing key: file-based in dev; behind a `Signer`

## Scaffold command supplied with the brief

```sh
sh <(curl 'https://ash-hq.org/install/breakline?install=phoenix') \
    && cd breakline && mix igniter.install ash ash_phoenix \
    ash_postgres ash_authentication ash_authentication_phoenix \
    ash_admin live_debugger mishka_chelekom ash_ai usage_rules \
    --auth-strategy password --setup --yes
```

Plus: "Make sure to only use mishka_chelekom for ui and ux". How this was actually run is in
`DECISIONS.md` (D2, D5).
