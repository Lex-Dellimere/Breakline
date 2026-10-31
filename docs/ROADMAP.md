# Roadmap

Each phase starts with a proposed plan and needs approval before work begins.

| phase | scope | status |
|---|---|---|
| 0 | repo, docs, dev db, scaffold core / gateway / cloud (ash + mishka-only ui) | done 2026-10-31 |
| 1 | core: `Policy`, `Schedule.state_at` with dst property tests, `Command` (ed25519), `AuditLog` hash chain + canonical json, `Catalog` from lolrmm snapshot + kev match keys | next |
| 2 | gateway: `Firewall` behaviour + `FakeImpl` + `NftImpl` (golden json), `DNS` resolver, `Enforcer`, persistence, supervision | |
| 3 | cloud domain (tenant, site, approver, msp_contact, policy, event), `Signer`, gateway channel + `Uplink` (slipstream, mtls). **first end-to-end demo** | |
| 4 | flows: msp magic-link window request → approver passkey approval → signed push; break-glass; kev/acsc polling via ash_oban; teams/slack/sms link-only notifications | |
| 5 | dashboard (site state + why, windows, timeline), audit export json + pdf with chain verification | |
| 6 | real nftables runs, pilot box, then nerves firmware (custom x86_64 system with nic drivers) | |

Open decisions parked for later phases:
- doh blocklist source and licence handling (phase 2 or 4)
- acsc-only matches: auto-lock or ask (phase 4)
- sms provider (phase 4)
- pdf library (phase 5)
- custom nerves system vs debian on the pilot box (phase 6)
