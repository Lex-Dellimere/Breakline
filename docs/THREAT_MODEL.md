# Threat model (draft, phase 0)

Living document. Update it whenever a phase adds a trust boundary or changes a mitigation.

## What we protect

The client's ability to say no to remote access. Specifically:
- **Enforcement state on the gateway:** the RMM channel is closed unless the client's policy says
  it is open right now.
- **Policy integrity:** only the client's approvers, or a published advisory, can change it.
- **The record:** a tamper-evident account of every open, close, approval and override.

## Trust boundaries

```
 client LAN hosts ──► gateway ──► internet (RMM SaaS relays, self-hosted RMM server)
                         │
                         └─ outbound wss + mtls ─► cloud ◄── approvers (browser, passkey)
                                                    ▲   ◄── msp contacts (magic link, no account)
                                                    └────── feeds: cisa kev, acsc rss, lolrmm
```

- The gateway trusts only commands signed with the cloud's Ed25519 key. It accepts no inbound
  connections.
- The cloud trusts approvers authenticated with a passkey for anything that opens access.
- Feeds are untrusted input. They can only add locks, never open access.

## Adversaries

| id | adversary | example |
|---|---|---|
| A1 | controls the MSP's RMM server or tenant | the Aug–Sep 2026 N-central campaign: RMM remote control used to reach client machines |
| A2 | phishes an approver or MSP contact | fake "approve maintenance window" message |
| A3 | compromises the Breakline cloud | stolen signing key, malicious deploy |
| A4 | sits on the network between gateway and cloud | hostile upstream, rogue wifi on the WAN side |
| A5 | is a LAN host trying to reach RMM infra anyway | DoH/DoT, hardcoded IPs, VPN, P2P |
| A6 | has physical access to the gateway | clinic back office |
| A7 | can influence the gateway's clock | NTP spoofing |

## Threats and mitigations

| # | threat | mitigation | residual risk |
|---|---|---|---|
| T1 | A1 uses the RMM during a locked period | dns NXDOMAIN for catalog domains; drop the resolved-ip set + static CIDRs + per-site self-hosted hosts; default state is locked | relays reached by IP without DNS; tools missing from the catalog |
| T2 | A5 bypasses gateway DNS | DNAT all client :53 to the gateway; drop :853; drop 443 to known DoH ips; NXDOMAIN for DoH names and the Firefox / iCloud Private Relay canaries; CNAME chains into catalog domains are blocked; tool-only ports dropped to any destination while locked (D19) | unknown DoH servers (NextDNS by name only), VPNs, a tool on a port shared with the web (443) talking to an ip we never resolved |
| T3 | forged unlock command | Ed25519 envelope bound to site_id; the gateway holds only the public key | A3 (see T8) |
| T4 | replay or rollback of an old "open" policy | strictly increasing version, expires_at, nonce cache, persisted last-applied version | gateway disk wiped and restored from an old image: re-provisioning must reset trust explicitly |
| T5 | A2 phishes an approver into approving | approve and break-glass require a passkey (phishing-resistant, origin-bound); notifications carry a link only, never an approve button | **until phase 4 the demo actions (open, lock, unlock) need only a password session.** TOTP fallback is phishable. Decide whether TOTP may approve, or only log in (phase 4) |
| T6 | A2 steals an MSP magic link | the link can only *request* a window (it is the actor of `Window :request` and nothing else); a client approver must still approve with a passkey. Only the sha256 of the 256-bit token is stored; links expire after 14 days and admins revoke them; unknown, expired and revoked tokens get one generic page. Caps: 3 pending and 10 per 24 h per link, at most 12 h long, start not in the past; 30 token lookups per ip per 10 min | the token is in the URL, so it can land in browser history and the request log line (`GET /request/<token>`); behind a proxy the per-ip limit needs the real client ip. Request spam within the caps still reaches approvers |
| T7 | gateway loses the cloud connection | keep enforcing the last good signed policy; windows are evaluated locally | an approval made while offline can't arrive. That is acceptable, because the gateway fails closed |
| T8 | A3 compromises the cloud | `Signer` behaviour so the key can move to KMS/HSM; audit chain; cloud can't push an older version | a compromised cloud can sign "open". Open question: should advisory locks be un-liftable before expires_at except by local break-glass? |
| T9 | audit log tampering | SHA-256 hash chain, `verify_chain/1`; the cloud keeps its own copy of each gateway chain, verified segment by segment, and anchors the head (D26); chain resets are recorded as events | records written on the gateway but not yet uplinked can still be truncated there; the cloud's own audit chain for approvals is phase 4/5 |
| T10 | A4 MITM between gateway and cloud | mtls both ways: the gateway trusts only the configured CA and checks the server hostname; the cloud requires a client cert whose sha256 fingerprint is pinned on the site (D25); signed payloads are verified anyway | denial of service, which is covered by T7. A TLS-terminating proxy in front of port 4011 would break this, so hosting must terminate TLS in the app |
| T11 | A7 skews the clock into a window | unsynced clock means RMM stays locked (fail closed) | an attacker who can spoof NTP well can shift time. Consider NTS, or a cloud-signed time sanity check |
| T12 | false-positive advisory locks out the MSP | locks only close access; per-tenant auto-lock or ask; break-glass exists | MSP friction during real incidents is by design |
| T13 | feed poisoning or parsing bugs | KEV is structured json with explicit match keys; ACSC is free text, so require CVE + product match and default to "ask" | a missed advisory (false negative): KEV lag vs ACSC |
| T14 | A6 tampers with the gateway | out of scope for v1 pilots. Nerves read-only rootfs and secure boot are later work | physical access defeats it |
| T15 | collateral blocking: a resolved RMM ip is a shared CDN address | ips are only learned from catalog names; monitor-mode pilots measure would-blocks before anyone enforces | while locked, unrelated sites on the same ip are blocked too. Review per tool with pilot data |
| T16 | power loss mid-write on the gateway | atomic tmp + fsync + rename for state files; audit appends are fsynced; a torn audit line is detected at boot and the chain restarts with a reset entry | the data directory isn't fsynced after rename, so the very last write can be lost (the old state stays valid) |

## Explicitly out of scope (v1)

- Endpoint compromise or RMM agents running as SYSTEM: there is no endpoint agent in v1.
- Off-site laptops: they never pass through the gateway.
- TLS SNI inspection.
