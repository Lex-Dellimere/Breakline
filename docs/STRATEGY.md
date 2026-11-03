# Strategy

Plan of record for how Breakline makes money. Decided 2026-11-01 (D46). Replaces the
"sell to clinics" target in `docs/BRIEF.md`. The product scope in the brief still holds.

## The decision

Keep the technology, change who pays. **MSPs are the customer**, not clinics.

Breakline is sold to MSPs as **a lock outside your RMM**. The MSP deploys it at its client
sites, and it decides per client who holds the key: its own senior staff, the client, or
both.

## Why

- **The real problem:** an RMM is a skeleton key to every client an MSP manages. When the
  RMM itself is compromised (N-central in Australia, August 2026), every control inside it
  is compromised too: consent prompts, allowlists, the MSP's own admin settings. The only
  control that survives is one outside the RMM's trust boundary. That is what Breakline
  already is: a gateway at the site that takes signed policies from its own cloud, not
  from the RMM.
- **Who feels it most:** the MSP. One compromised RMM hits all of its clients at once, and
  the liability, the insurance renewal and the reputation are all the MSP's. A single
  clinic feels the risk only through its MSP.
- **The market scan's weak points go away with this buyer:**
  - *MSP veto* becomes the channel: the MSP is the buyer and the installer.
  - *Tiny buyers* get bundled: an MSP with 40 clinic clients is one sale with 40 sites.
  - *Install friction* goes: the MSP already controls the network edge.
  - *"We already have consent prompts"* turns into the pitch: those live inside the thing
    that gets compromised.
- **What stays weak:** demand is still unproven. Gating can still break the MSP's own
  automation if the remote-control channel can't be told apart from patching and
  monitoring for a tool. And it is a small, Australia-first market. Validation comes
  before any more building.

## The offer (hypothesis, to test)

1. **Emergency lockdown (the lead, D51):** within 30 minutes of the MSP's RMM appearing in
   CISA KEV, remote access closes at every client site that uses it (an ACSC alert asks
   first). It reopens when an admin lifts the lock with a passkey after patching. This
   works even if the RMM console is owned by an attacker.
2. **Windows and approvals, optional per client:** remote-control sessions need a booked
   window or a passkey approval from the MSP's senior staff or the client. This fits pure
   remote-control tools (AnyDesk, TeamViewer, Splashtop, ScreenConnect, Take Control). For
   NinjaOne and Datto a lock may also pause patching; the pilots measure it (D52).
3. **An access report per client:** a tamper-evident PDF of every open, close, approval
   and lockdown. It is for the client, for the MSP's and the client's insurers, and for
   accreditation evidence (RACGP F8 asks for remote access obligations in IT contracts).

**Deployment is software-first:** the `.deb` runs on any x86 box or VM the MSP already
deploys. DNS-only monitor mode needs nothing inline. Breakline holds no hardware stock.

**Pricing hypothesis:**
- MSP wholesale AUD 25–45 per site per month; the MSP sets its own resale price.
- The first 5 sites are free during a pilot.
- This replaces the scan's AUD 149 direct-to-clinic price. **Not validated.**

## Validation: 8 weeks, then a decision

**Gate date: 2026-12-29.**

| weeks | what | who |
|---|---|---|
| 1 | target list of MSPs; outreach drafts; site and one-page offer reworded for MSPs | Claude |
| 1–4 | 8 MSP conversations, using the scan's interview script plus 3 offer questions at the end | owner talks, Claude prepares and debriefs |
| 3–8 | 2 MSPs run monitor mode on their own office or 1–3 client sites; measure RMM traffic by hour and channel | MSP installs, Claude supports |
| 8 | decide | Claude recommends, owner agrees |

**Decision rules:**
- **Continue** if at least 2 of the 8 MSPs commit to a paid pilot or sign a letter of intent
  at any price.
- **Reshape** if MSPs want only the automatic lockdown. Then build that alone as a lighter
  product (it needs no client-side approvals at all).
- **Stop selling** if fewer than 2 of 8 show active interest (asking for a pilot or a
  price). The code then stays a research artefact.

**Questions to add at the end of each MSP interview** (only after the open questions in
the scan's script):
1. "When N-central was exploited in August, what could you have done in the first hour?"
2. "If one box at each client could close remote access the moment your RMM appears in
   CISA's list, and only your senior staff could reopen it, what would that be worth to
   you per site?"
3. "Would any client, insurer or auditor of yours want proof of every remote session?"

## Audience: RMM Watch AU

A short weekly note for Australian MSPs and IT managers. It covers which RMM and
remote-access tools appeared in CISA KEV or ACSC advisories that week, and what to do. It
is built from the advisory polling and tool catalogue Breakline already runs.

- It builds credibility and a list of interested MSPs at almost no cost.
- Every issue cites its sources and is approved by the owner before it goes out.

## Who does what

**Claude:**
- research and product decisions;
- all code, the website, docs and pricing;
- interview prep and debriefs;
- drafts of every message, agreement and newsletter issue;
- deciding when to stop.

**The owner (only what needs a person):**
- the legal entity (ABN or company);
- accounts and payments: domain, hosting, Postmark, later Stripe;
- sending each message (each one needs their yes);
- calls and meetings;
- signing agreements, after a lawyer reads anything binding;
- anything physical.

**The salesperson (a friend of the owner, unpaid for now, from 3 Nov 2026):** finds MSPs,
sends the emails and makes the calls, working from the "Breakline sales starter" doc
(script, objections, target list, call log). He isn't technical: technical questions come
back to the owner and Claude.

Revenue belongs to the owner. Claude can't hold money.

## Rules that don't bend

- Nothing is sent, published, bought or signed without the owner's explicit yes, each time.
- No claims of compliance, certification or insurance benefit until they are verified with
  the body that grants them.
- Enforce mode is not sold until monitor-mode pilots show it doesn't break an MSP's
  automation.
