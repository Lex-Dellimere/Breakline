# Breakline

Client-owned site gateway that keeps an MSP's RMM / remote-control channel **closed unless a
window is booked or a client approver approves**, and **auto-closes it** when that tool is under
active exploitation (CISA KEV / ACSC). Target: Australian mid-sized, site-heavy businesses that
use an MSP.

Demand is not validated. v1 exists to demo in customer interviews and run monitor-only pilots:
optimise for a working, demo-able slice, not completeness.

- Brief (source of truth for scope): `docs/BRIEF.md`
- Phases and status: `docs/ROADMAP.md`
- Every decision and why: `docs/DECISIONS.md`
- Threats and mitigations: `docs/THREAT_MODEL.md`

## Layout (poncho, Elixir everywhere)

| dir | otp app | modules | what |
|---|---|---|---|
| `core/` | `:breakline` | `Breakline.*` | pure lib: policy, schedule, catalog, signed commands, audit chain. No processes, IO or global config; pass `Breakline.time_zone_database/0` explicitly |
| `cloud/` | `:cloud` | `Cloud.*`, `CloudWeb.*` | Phoenix 1.8 + LiveView + Ash 3 + AshPostgres. Read `cloud/AGENTS.md` (usage rules) before working there |
| `gateway/` | `:gateway` | `Gateway.*` | OTP app: dns resolver, firewall, uplink, enforcer. Runs on a Linux host in dev, Nerves later |
| `firmware/` | | | Nerves project wrapping gateway (phase 6, not started) |

`cloud` and `gateway` depend on `core` by path.

## Working rules

- Planning, architecture decisions and reviews: Opus, high effort. Coding subagents: Opus, medium
  effort. Lookups and research (lib docs, feed formats): Sonnet or Haiku.
- Propose a plan before each phase and wait for approval.
- Small commits. `mix test` green in every app you touched before moving on.
- Ask before adding a dependency that isn't already in a `mix.exs` or named in `docs/BRIEF.md`.
  Verify every lib and feed URL before using it.
- Log every decision, with the reason, in `docs/DECISIONS.md`.
- Never commit secrets or keys. Dev keys are generated locally under `priv/keys/` (git-ignored).

## Style

- Commit messages: all lowercase, plain human style, no emoji, no co-author or other trailers.
  Example: `add schedule state_at with dst property tests`.
- Code comments: lowercase, no emoji.
- UI: **mishka_chelekom components only** (generated into `cloud/lib/cloud_web/components/`).
  No daisyUI, no Phoenix CoreComponents, no ash_authentication_phoenix built-in UI. ash_admin and
  live_debugger are dev-only tools and the only exceptions.

## Dev environment

- `docker compose up -d` starts Postgres 17 as `breakline-pg` on `127.0.0.1:5433`. Port 5432 on this
  machine belongs to another project's container: never use it.
- cloud: `cd cloud && mix setup && mix phx.server`, then http://localhost:4010 (4000 is taken).
  Dev only: ash_admin at `/admin`, live_debugger on port 4017.
- Tests: `mix test` in `core/`, `gateway/` and `cloud/`.
- `nft` is not installed on the dev host. Firewall code is tested through the fake impl and golden
  `nft -j` json; real nftables runs come later in a netns or VM.
- Binding :53 needs root, so the dev gateway resolver listens on a high port.

## Non-goals (v1)

No Windows/macOS endpoint agent, no mass-push/behavioural detection, no rogue-RMM inventory, no
off-site laptop coverage, no TLS SNI inspection, no MSP partner portal.
