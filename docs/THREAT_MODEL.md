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
| T2 | A5 bypasses gateway DNS | DNAT all client :53 to the gateway; drop :853; drop 443 to known DoH ips; NXDOMAIN for DoH names and the Firefox / iCloud Private Relay canaries; CNAME chains into catalog domains are blocked; tool-only ports dropped to any destination while locked (D19); the resolver is dual-stack (`::`), so v6 clients are redirected too (D43) | unknown DoH servers (NextDNS by name only), VPNs, a tool on a port shared with the web (443) talking to an ip we never resolved. Bridge mode without br_netfilter, or with a bridge port named as the LAN interface, fails open; the gateway reports it in `host_problems` (D43) |
| T3 | forged unlock command | Ed25519 envelope bound to site_id; the gateway holds only the public key | A3 (see T8) |
| T4 | replay or rollback of an old "open" policy | strictly increasing version, expires_at, nonce cache, persisted last-applied version | gateway disk wiped and restored from an old image: re-provisioning must reset trust explicitly |
| T5 | A2 phishes an approver into approving | every action that opens access (open now, approve a request, break-glass, lift a lock, remove a passkey) consumes a per-action passkey step-up bound to the actor, purpose, subject and a hash of the exact parameters, single use, 2 min, enforced in the resource layer (D28). TOTP is a sign-in factor only and never approves. Notifications carry one line and a link, never an action, button or token (D31) | a fully compromised approver device can still approve. Passkey sign-in skips TOTP by design (the passkey is the stronger factor) |
| T6 | A2 steals an MSP magic link | the link can only *request* a window (it is the actor of `Window :request` and nothing else); a client approver must still approve with a passkey. Only the sha256 of the 256-bit token is stored; links expire after 14 days and admins revoke them; unknown, expired and revoked tokens get one generic page. Caps: 3 pending and 10 per 24 h per link, at most 12 h long, start not in the past; 30 token lookups per ip per 10 min | the token is in the URL, so it can land in browser history and in a proxy's logs (the app no longer logs the path, D37); behind a proxy the per-ip limit needs the real client ip. Request spam within the caps still reaches approvers |
| T7 | gateway loses the cloud connection | keep enforcing the last good signed policy; windows are evaluated locally | an approval made while offline can't arrive. That is acceptable, because the gateway fails closed |
| T8 | A3 compromises the cloud | `Signer` behaviour so the key can move to KMS/HSM; audit chain; cloud can't push an older version | a compromised cloud can sign "open". Open question: should advisory locks be un-liftable before expires_at except by local break-glass? |
| T9 | audit log tampering | SHA-256 hash chain, `verify_chain/1`; the cloud keeps its own copy of each gateway chain, verified segment by segment, and anchors the head (D26); chain resets are recorded as events; an audit export carries the chain heads and re-verifies offline with `mix breakline.audit.verify` (D35) | records written on the gateway but not yet uplinked can still be truncated there. The cloud's per-tenant chain (D29) shares a database with its head row, so someone with write access to the database can rewrite both together; anchoring cloud heads outside the database is later work |
| T10 | A4 MITM between gateway and cloud | mtls both ways. At enrolment the box pins the 4011 CA by its SubjectPublicKeyInfo sha256, then trusts only `server_ca.pem` and checks the host name. The cloud requires a client certificate whose fingerprint is pinned on the site: self-signed, with possession proven by the TLS handshake (D41). Signed payloads are verified anyway | denial of service, which is covered by T7. A TLS-terminating proxy in front of port 4011 breaks enrolment and the socket, so hosting must terminate TLS in the app. The offline CA key can impersonate the cloud to every box, but it cannot sign policies |
| T11 | A7 skews the clock into a window | unsynced clock means RMM stays locked (fail closed) | an attacker who can spoof NTP well can shift time. Consider NTS, or a cloud-signed time sanity check |
| T12 | false-positive advisory locks out the MSP | locks only close access; per-tenant auto-lock or ask; break-glass exists | MSP friction during real incidents is by design |
| T13 | feed poisoning or parsing bugs | KEV is structured json with explicit match keys; ACSC is free text, matched by CVE-via-KEV or whole-word product name, and always "ask" (D30); the RSS parser refuses xml entities (no XXE); the first fetch of each feed is a baseline that acts on nothing | a missed advisory (false negative): KEV lag vs ACSC; guessed KEV product keys for tools CISA has never listed |
| T14 | A6 tampers with the gateway | out of scope for v1 pilots. The pilot box runs Debian with the gateway as an unprivileged service holding two capabilities (D40). Nerves read-only rootfs and secure boot are later work | physical access defeats it: the disk is unencrypted (an unattended reboot can't take a passphrase), so the cookie and state can be read |
| T15 | collateral blocking: a resolved RMM ip is a shared CDN address | ips are only learned from catalog names; monitor-mode pilots measure would-blocks before anyone enforces | while locked, unrelated sites on the same ip are blocked too. Review per tool with pilot data |
| T16 | power loss mid-write on the gateway | atomic tmp + fsync + rename for state files; audit appends are fsynced; a torn audit line is detected at boot and the chain restarts with a reset entry | the data directory isn't fsynced after rename, so the very last write can be lost (the old state stays valid) |
| T17 | notification webhook secrets leak | every channel target is encrypted at rest (AES-256-GCM, key from `NOTIFICATIONS_KEY` or secret_key_base); the UI shows only the webhook host; only exact Slack and Teams Workflows hosts are allowed, https only, no redirects (also blocks SSRF) | no key rotation yet; a leaked database plus the key exposes webhooks |
| T19 | audit details carry Typst markup or code into the PDF renderer (`#read`, `#import` of a package, `#eval`) | data goes to Typst only as `data.json` and every value is set as text: nothing is evaluated or written into source; the template imports nothing and reads only `data.json`; each render has its own temp root, embedded fonts only, a 60 s timeout and a 20,000 record cap (D38) | a bug in Typst itself (it runs as a separate process, not inside the VM); a request that dies mid-render leaves the render running until its timeout |
| T18 | notification spam or mis-delivery | messages go only to the tenant's own channels and its admins/approvers; user-supplied names are reduced to plain text so they can't inject links or mentions | with several cloud nodes each dispatcher would send duplicates (single node in v1; outbox fix noted in D31) |
| T20 | a local user or a compromised process on the box drives the gateway's VM over erlang distribution | no epmd; distribution listens on 127.0.0.1:4370 only; a per-box cookie readable only by `breakline`; the build cookie never ships (D40) | root on the box, or code running as `breakline`, controls the gateway |
| T21 | the OS's own nftables config deletes the gateway's table (Debian's stock `/etc/nftables.conf` starts with `flush ruleset`) | `docs/PILOT.md` and the examples say never to enable it; the gateway only ever touches `table inet breakline`, and every evaluation re-applies it when it is gone (D43) | up to one tick (15 s) with no rules, and the resolved-ip sets refill only from new lookups |
| T22 | availability: an inline box has no bypass port, so a dead box cuts the site off; a dead dns-only box stops name lookups | dns-only monitor first; a UPS, BIOS power-on after AC loss, `Restart=always`, and a documented rollback (`docs/PILOT.md`) | in dns-only mode a second DHCP resolver adds resilience but lets lookups bypass the box |
| T23 | a stolen or intercepted enrolment code enrols an attacker's box and displaces the real one | issuing needs an admin and a passkey step-up bound to the site (T5); single use, 30 minutes, a new code cancels the old one, and admins can cancel; only the hash is stored, one refusal for every bad code, 20 tries per ip per 10 minutes; the pin comes from the TLS session, so the code is useless without a key the attacker holds; the box pins the CA, so a MITM can't relay the code; issue and use are audited with both fingerprints and the ip; an attacker's box can only receive signed policies and report, so it can't open access at the real site, which keeps enforcing its last policy (T7) | a code read off a screen within 30 minutes can be used first: the real site then gets no new policies until an admin re-enrols (a denial of service), and the attacker's box can send the cloud fake heartbeats, events and audit records for the site. Behind a layer 4 forwarder the rate limit sees the forwarder's ip. Later: show the presented fingerprint for confirmation before pinning, or notify the tenant's channels on every enrolment |
| T24 | the gateway's resolver is used from the WAN side (an open resolver, amplification) | an `input` chain drops the resolver port unless it arrives on `lo` or a LAN interface (D43) | in bridge mode the management ip is reachable from both sides of the bridge |
| T25 | the gateway process dies or crash-loops | the nft table and its drops stay; an open window's lock rules sit behind `meta time >= locks_at`, so the kernel ends the window on time without the BEAM (D43); the unit restarts it every 5 s without limit | while it is down, clients get no DNS (fail closed, but an outage); an open state with no end inside the 14-day horizon stays open until restart |

## Explicitly out of scope (v1)

- Endpoint compromise or RMM agents running as SYSTEM: there is no endpoint agent in v1.
- Off-site laptops: they never pass through the gateway.
- TLS SNI inspection.
