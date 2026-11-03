# Handoff

Where Breakline stands on 4 Nov 2026 and how to pick it up. Read this first, then
`docs/STRATEGY.md`. Every decision and its reason is in `docs/DECISIONS.md` (D1–D53).

## In one paragraph

Breakline is a gateway at each client site, sold to Australian MSPs as "a lock outside your
RMM". Within 30 minutes of the MSP's remote-access tool appearing on CISA's
exploited-vulnerabilities list, remote access closes at every client site that uses it, even
if the RMM console itself is compromised. An admin reopens it with a passkey after patching.
Booked windows and approvals are optional per client. The product is built and tested end to
end. Demand is not proven yet: the test runs until 29 Dec 2026.

## Who is who

- **The owner (the user):**
  - holds a sole-trader ABN and the budget (AUD 300 to the gate);
  - makes calls and visits;
  - does every step that needs a person: accounts, payments, sending messages, signing.
  - Revenue is theirs.
- **Claude:** runs the project as owner of operations (strategy, research, code, docs). It
  decides and logs; it doesn't ask the owner questions, it gives them to-dos.
  - Coding goes to Opus 5.5 subagents at medium effort with tight briefs.
  - The owner is strict on usage credits.
- **The salesperson:** a friend of the owner, not technical, unpaid for now. He makes the
  calls and emails from the "Breakline sales starter" doc.

## State of the product

| Part | State |
| --- | --- |
| Cloud (Phoenix, Ash) | Passkeys and step-up, sites, windows, break-glass, KEV and ACSC advisories with auto-lock, a "Lift lock" for feed locks, gateway enrolment, audit chain and PDF export. Prod release builds; Postmark email when a key is set (D45). |
| Gateway | DNS resolver plus nftables. Fails closed; a window's end is held in the kernel even if the process dies (D43). Records the channel of each RMM lookup (D52). |
| Pilot box | Debian 13 `.deb`, hardened systemd unit, three install modes (D40, `docs/PILOT.md`). Never run on real hardware yet. |
| Catalogue | 8 tools, 61 domains, each tagged control, management or both. NinjaOne and Datto are `both`: a lock may pause their patching too. |
| Tests | core 165, gateway 242, cloud 363, plus the Docker suites (`--only nft_docker`, `traffic`, `deb_docker`) and the full-stack check in `e2e/`. |
| Hosting | Not deployed. The plan is `docs/DEPLOY.md`: a BinaryLane Sydney 2 GB VPS (AUD 9.80 a month ex GST) and the domain breaklinesecurity.com.au. Bought only when an MSP agrees to a pilot (D48). |

## Sales material

- Product brief (Claude Docs, private until shared): https://claude.ai/artifact/BWMrx8ktyKFZy8ACSWPsWx
- Sales starter for the salesperson (Claude Docs): https://claude.ai/artifact/UB5dD3aFWs3mhv9K4WeU52
  - plain-English explanation, glossary, word-for-word script and objection answers;
  - 10 target MSPs with a status dropdown;
  - **the call log, which is the source for the gate tally.**
- Market scan: `docs/research/market-scan.html`. Buyer and channel research (35 MSPs, events, insurers, KEV dates): `docs/research/buyers-and-channels.md`.
- One-pager: `docs/sales/breakline-one-pager.pdf` (source `one-pager.typ`, rendered with `cloud/priv/bin/typst`).
- Demo video (about 75 s, no voice yet): rebuild with `VIDEO=1 e2e/run.sh` (see `e2e/README.md`). It shows a test KEV entry auto-locking a site and cutting a live session, then a passkey reopening it (D53).
- Targets and drafts: `docs/sales/targets.md`, `docs/sales/outreach.md`. Voice-over script: `docs/sales/video-script.md` (12 lines).

## Waiting on the owner

1. Share both Claude Docs with the salesperson, and send him the video and the one-pager.
2. Agree how the salesperson is paid before any money comes in.
3. Record the voice-over from `docs/sales/video-script.md`, with a 2-second pause after each line, and attach it in the session.

## Next for Claude

- **When the voice-over arrives:**
  1. split it at the silences and clean it with ffmpeg;
  2. set each scene's pause in `e2e/flow.cjs` from its line length;
  3. re-record with `VIDEO=1` and mix in the audio.
- Read the call log in the sales starter and keep the tally against the gate.
- **When an MSP agrees to a pilot:**
  1. give the owner exact prices to buy the domain and the VPS, and set up Postmark;
  2. deploy per `docs/DEPLOY.md`;
  3. build a small pilot report of control vs management traffic from the D52 data;
  4. run the pilot in monitor mode.
- Add a tool to the catalogue (ConnectWise RMM, Atera, Kaseya VSA, Syncro and so on) as soon as a prospect uses one.

## The gate (29 Dec 2026)

- **Continue** if at least 2 MSPs commit to a paid pilot or a letter of intent.
- **Reshape** if they only want the lockdown and not the rest.
- **Stop selling** if fewer than 2 of about 8 show real interest.

## Known limits (told honestly in the material)

- It closes the RMM's own channel. It can't remove an attacker who is already inside: the
  August N-central attackers set up tunnels.
- Bypass is possible through hardcoded IPs, unknown DoH servers, VPNs, or tools not in the
  catalogue (T1, T2).
- Enforcing needs the box in the network path (DNS or inline). Pilots are monitor-only.
- The cloud signing key is a file. A KMS or HSM, and an external security review, wait for
  revenue (T8, D51).

## Two outside audits

On 3 and 4 Nov 2026 another AI reviewed the repo. The owner said to treat those reviews as
conversation, not truth. Their verified points went into D51–D53:
- lead with the lockdown;
- tag channels;
- Datto coverage;
- honest "within 30 minutes" wording;
- show the automatic lockdown in the demo.

Their business verdict matches the strategy: credible niche, unproven demand, weak as a
venture, plausible bootstrapped or as an acquired feature.

## Working rules

- Commits and code comments are lowercase with no emoji and no trailers. The UI uses mishka_chelekom only. Never use port 5432; the dev DB is on 5433. Cloud dev runs on 4010.
- Keep durable state in the repo, never only in scratch space: a restart once wiped it.
- Nothing is sent, bought, published or signed without the owner doing it or saying yes.
