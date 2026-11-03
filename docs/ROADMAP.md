# Roadmap

Each phase starts with a proposed plan and needs approval before work begins.

| phase | scope | status |
|---|---|---|
| 0 | repo, docs, dev db, scaffold core / gateway / cloud (ash + mishka-only ui) | done 2026-10-31 |
| 1 | core: `Policy`, `Schedule.state_at` with dst property tests, `Command` (ed25519), `AuditLog` hash chain + canonical json, `Catalog` from lolrmm snapshot + kev match keys | done 2026-10-31 |
| 2 | gateway: `Firewall` behaviour + `FakeImpl` + `NftImpl` (golden json), `DNS` resolver, `Enforcer`, persistence, supervision | done 2026-10-31 |
| 3 | cloud domain (tenant, site, approver, msp_contact, policy, event), `Signer`, gateway channel + `Uplink` (slipstream, mtls). **first end-to-end demo** | done 2026-11-01 |
| 4 | flows: msp magic-link window request → approver passkey approval → signed push; break-glass; kev/acsc polling via ash_oban; teams/slack/sms link-only notifications | done 2026-11-01 |
| 5 | dashboard (site state + why, windows, timeline), audit export json + pdf with chain verification | done 2026-11-01 (pdf with the typst cli, D38) |
| 6 | real nftables runs, pilot box, then nerves firmware (custom x86_64 system with nic drivers) | done 2026-11-01 without nerves: real traffic suite (D43), debian pilot box `.deb` (D40), gateway enrolment (D41), cloud release and hosting guide (D42), full-stack check (D44) |
| v | validation (business, not a build phase): sell to msps (D46), lead with the emergency lockdown (D51), channel tags (D52), demo of the automatic lockdown (D53), outreach by the salesperson | in progress; gate 2026-12-29 (`docs/STRATEGY.md`) |
| 7 | nerves firmware: custom x86_64 system with the pilot box's nic drivers, read-only rootfs, secure boot | after the pilots settle the hardware |

Open decisions parked for later phases:
- doh blocklist source and licence handling (still deferred: own list in use, GPL lists would be fetched by the cloud)
- ~~acsc-only matches: auto-lock or ask~~ resolved: ask (D30)
- sms provider (dev adapter in place, D31)
- ~~email provider for prod~~ resolved: postmark when `POSTMARK_API_KEY` is set, a soft failure without it (D45); the owner creates the account when a pilot is agreed
- pilot report of control vs management traffic (D52 records it; build when an msp agrees a trial)
- more tools (connectwise rmm, atera, kaseya vsa, syncro): add when a prospect uses one
- ~~pdf library (phase 5)~~ resolved: the typst cli as a separate process (D38)
- ~~custom nerves system vs debian on the pilot box (phase 6)~~ resolved: debian for the pilots (D40), nerves after them (phase 7)

Ideas parked for later:
- ~~landing page crawling squares (user idea, tagged 4.2)~~ built in phase 4 (D33)
