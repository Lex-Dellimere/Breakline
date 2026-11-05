# Pivot research: what Breakline's technology should sell instead

Desk research, 6 Nov 2026. Eight narrow web gatherers (Haiku) plus two checks of my own. Nobody
was contacted and nothing was signed up for.

**Brief as amended mid-research:** rank purely on money or time saved, and on how easily a
non-technical salesperson can sell it on a 10-minute call. Security does not appear as a reason
to buy, not even as a side benefit. The existing code is treated as general plumbing, and reuse
is only a tiebreaker:

- a box in each client network that sees every DNS lookup and can switch traffic on a schedule;
- a cloud that runs many sites for one MSP;
- approvals and PDF reports.

## Source tags

- **[F]** A gatherer opened the page and reported it (URL given). WebFetch returns a small-model
  summary, so re-read anything before quoting it to a customer.
- **[X]** Search snippet only, or my own inference or arithmetic (marked "inference").
- Reddit could not be fetched directly. The r/msp material was read through a mirror
  (`reddit.sentinel-team.org`), which is noted each time it is used.

## The answer in one paragraph

None of the starting hypotheses is strong. Most fail on the money argument:
- insurers publish no premium discounts;
- DNS filtering is free or about A$1–2.50 a user;
- telcos already bundle internet failover;
- remote-session billing is mostly covered by PSA integrations, and Australian MSPs mostly bill
  a flat fee per user.

The one shape where the box itself earns money is **the box as a sales tool for the MSP**: put
it at a prospect's site for two weeks and hand back a plain-English report. The report covers
the apps the office actually uses, internet outages and slowness, and devices on the network.
It turns one sales conversation into a signed client, and the box then stays on as the monthly
or quarterly review (QBR) report.

The money argument is one the MSP can check against its own books. A 20-seat client is worth
about **A$29k–63k a year in revenue** to an Australian MSP [F], and the assessment would cost
about A$150. That is still a hypothesis. No independent data shows that assessments raise close
rates (only vendor claims of 25–70% [X]). The existing competitors sell on risk findings, which
this version leaves out. So validate it with MSP calls before building anything. The clinic
internet-continuity idea is the runner-up: easiest to explain and the father is a warm lead, but
the telco's own modem already does most of it. If MSPs won't pay for the report by 29 Dec, take
the kill option below.

---

## 1. Questions, hypotheses, and what would confirm or kill each

| # | Hypothesis | Confirm if | Kill if | Result |
|---|---|---|---|---|
| H1 | DNS-based SaaS and shadow-IT discovery for MSP QBRs (licence waste, upsell) | MSPs pay for SaaS discovery; waste is big at 10–50 staff; no network-based tool exists | Discovery is free or bundled; small offices have little SaaS spend | **Weak as a product of its own; useful as a report section.** No DNS-only MSP tool was found, so there is a gap. But Kaseya bundles SaaS Alerts free, and small clinics spend little on SaaS (see option 3) |
| H2 | Remote-session time capture to stop unbilled MSP time | Leakage is large; session time is not already pushed into the PSA; contracts are hourly | Flat-fee contracts dominate; PSA integrations already log session time | **Weak.** Leakage figures are vendor guesses (3–10% of revenue [F]). Some integrations already auto-log. AU MSPs mostly charge per user (option 5) |
| H3 | Automated compliance and insurance evidence saves MSP hours | MSPs spend many hours per client; a gateway can prove many items | A gateway can prove few items; evidence-heavy forms are rare | **Weak.** "A few hours" per form [F]. Evidence-heavy forms are uncommon (r/msp via mirror [F]). Most items are endpoint or cloud facts a site box cannot see |
| H4 | Cut cyber-insurance premiums with provable controls | A named AU insurer publishes a discount for a control | Only "required for cover" or unsourced percentages | **Kill.** No published AU discount found. Cover uptake is below 4% of small businesses [F] |
| H5 | Bandwidth or productivity filtering | Paid demand at a price a newcomer can win | Free tiers, price under A$2 a user, legal friction | **Kill.** Commodity, with free tiers. NSW needs 14 days' written notice before monitoring staff [F] |
| H6 (added) | MSP prospecting box: assess a prospect's site to win the deal, then keep it for QBRs | MSPs already pay for assessment tools; a new client is worth a lot; there is room under US prices | Assessments only sell on risk; MSPs won't place a box at a prospect | **Best available, unproven** (option 1) |
| H7 (added) | Clinic internet continuity: automatic failover plus outage proof | Outages are frequent and costly; clinics have no automatic backup | Telcos bundle automatic backup cheaply | **Runner-up, crowded** (option 2) |
| H8 (added) | Cheap per-site network and uptime monitoring for MSPs | Price gap under Domotz and Auvik | Free UniFi and RMM tools cover it | **Folded into options 1 and 3**; not strong alone |

Questions that only interviews can answer (desk research cannot):

1. How many prospects does an MSP pitch a quarter, what is its close rate, and what does it use to assess a prospect today?
2. Would an MSP owner put a box (or a VM) on a prospect's network for two weeks, and would the prospect let it handle DNS?
3. Without risk findings, does a report on apps, outages and devices move a prospect at all?
4. How many hours did the clinic lose to internet outages in the last 12 months, and does its modem already fail over?

---

## 2. Options ranked

### Option 1 (recommended): "Win the client" box for MSPs, which stays on as the QBR report

**One-line pitch:** "Drop this at a prospect's office for two weeks and walk in with a report that shows them what their IT is really doing. One won client pays for years of it."

**Who pays and what for:** the MSP owner, per assessment (or a flat monthly fee for unlimited
assessments), plus a small per-site monthly fee once the client signs and the box stays on for
QBRs.

**Money or time argument:**
- An Australian MSP charges A$119 / A$179 / A$264 per user a month ex GST [F
  https://www.stanfieldit.com/blog/managed-it-services-cost/]. Another AU MSP quotes A$150–250
  [F https://kmtech.com.au/information-centre/managed-service-provider-rates-comprehensive-pricing-guide/].
- So **a 20-seat client is worth about A$28.6k–63.4k a year in revenue** (inference from the
  two pages; revenue, not margin).
- If the hypothesised assessment price is A$149, one extra win a year pays it back about 190
  times (inference).
- Profit is the top concern for 91% of Australian MSPs, per an Ingram Micro study [F, cited in
  `buyers-and-channels.md` §4.4].
- Close-rate uplift: vendor claims only. audIT says "up to 70%", Marketopia says 25–50% [X].
  **No independent data.**
- After the sale, the same box feeds the QBR. QBR prep takes 1–2 hours per client for 33% of
  MSPs and 2–4 hours for 28% (ScalePad survey, vendor, 1,081 MSPs) [X]. None of the QBR tools
  the gatherer opened reports site internet uptime or outages:
  - ScalePad [F https://scalepad.com/lifecycle-manager/pricing];
  - Strategy Overview [F https://www.strategyoverview.com/pricing];
  - Liongard [F https://support.liongard.com/en/articles/15214878-support-qbrs-with-data-backed-operational-insights].

**What the report would show (no security content):**
- the apps and cloud services the office actually uses, and which ones overlap (for example
  Dropbox and OneDrive and Google Drive);
- internet outages with timestamps, and DNS slowness by hour;
- how many devices are active on the network;
- a "cost of current IT" page the MSP fills in;
- branded with the MSP's logo, as a PDF.

**Competitors and prices:**

| Product | Price | Source |
|---|---|---|
| RapidFire Network Detective Pro (Kaseya) | quote-only; an old guide gives under US$6k/yr ($499/month). Sold as "Prospecting, Auditing and Discovery" | [F https://www.rapidfiretools.com/solutions/msp/] [X price] |
| ConnectSecure | "as low as $300 per month", 14-day trial | [F https://connectsecure.com/pricing] |
| Galactic | free initial assessment, recurring assessments, 1,000+ MSPs, no price | [F https://galacticsecurity.com/] |
| Liongard | per user, quote-only (about $29 per environment per snippet) | [F https://www.liongard.com/pricing] [X] |
| Domotz (site monitoring, the nearest per-site anchor) | €35 per site per month, €17.50 at 500+ sites | [F https://www.domotz.com/pricing.php] |

All of these are US or EU priced and lead with security or network-device findings. None
reports which apps an office uses from DNS (inference from the pages opened).

**Code reused:**
- the gateway resolver in monitor mode (DNS-only, nothing inline);
- the `.deb` and the three install modes;
- enrolment and the mTLS uplink;
- multi-site cloud views for one MSP;
- PDF export;
- the catalogue pattern, retargeted from remote-access tools to SaaS and app domains;
- the uplink heartbeat, which already tells the cloud when a site is offline.

**New (estimate 3–5 weeks):**
- an app catalogue of about 200 SaaS domains mapped to app names;
- per-device lookup aggregation by client IP;
- outage and latency logging (upstream probes);
- a report template and an MSP-branded PDF;
- a "loan" flow: enrol the box to a prospect, end the trial, convert it to a client.

**Risks:**
- **The hook may be too weak without risk findings.** Competitors sell on scary findings, and a
  report on apps and outages may not move a prospect. This is the biggest unknown.
- **Install friction at a prospect:** someone must point the office's DNS at the box. The
  prospect has to agree and the MSP needs router access before it is their client.
- **The office-only view misses home and mobile use.** With hybrid work, the app list is
  incomplete.
- **MSPs already own Network Detective or Galactic.** Then this has to be cheaper or simpler, or
  bundled with the QBR use.
- The non-technical salesperson can say the pitch, but the buyer will ask "how is this
  different from Network Detective?". He needs a one-line answer: "no scanning and no agents,
  just plug it in; Australian pricing; it stays on as your QBR report."

**How to validate by 29 Dec:**
1. Week 1 (Claude): build only the report from existing D52-style DNS logs, run it against the
   dev gateway, and render a sample PDF. Use made-up data clearly labelled as sample. No new
   infrastructure.
2. Weeks 1–4 (salesperson and owner): call the same 8–10 MSPs and ask the four interview
   questions above. Show the sample PDF.
3. Ask for a concrete commitment: "Put it at one prospect or one existing client in December;
   A$149 if you use the report in a sales meeting."
4. **Continue** if 2 or more MSPs agree to pay per assessment or sign a letter of intent.
   **Kill** if MSPs say "we use Network Detective or Galactic and it's fine", or "a report
   without risk findings won't close anything".

---

### Option 2 (runner-up): clinic internet continuity, with automatic failover and outage proof

**One-line pitch:** "When the NBN drops, your bookings, payments and telehealth keep working, and you get a log of every outage to take to your provider."

**Who pays and what for:** the clinic, directly or through its MSP: a monthly fee for failover
plus monitoring.

**Money or time argument:**
- A physio initial consult pays about A$119–137 under 2026 government fee schedules (TAC
  Victoria A$134.11, WorkSafe Qld A$137 ex GST) [X, search snippets of the schedules].
- A four-practitioner clinic seeing about 1.5 patients per practitioner-hour for 8 hours is
  roughly 48 consults, or **about A$4k–6k of bookings a day at risk** (inference, not measured).
- What outages do in practice:
  - the 2023 Optus outage halved one practice's SMS reminders and stopped billing and eScripts;
    that practice then added Starlink [F
    https://www1.racgp.org.au/newsgp/professional/clinic-preparedness-key-to-surviving-optus-collaps];
  - a Tasmanian foot clinic was down for almost five days [F
    https://www.examiner.com.au/story/4675675/internet-woes-hit-hard/].
- Telcos pay little back. Aussie Broadband pays compensation only for outages of two days or
  more, and won't reimburse backup costs [F
  https://www.aussiebroadband.com.au/help-centre/accounts-and-billing/what-compensation-is-offered-for-outages/].
- **No measured AU clinic cost per hour of downtime was found.**

**Competitors and prices:**

| Product | Price | Source |
|---|---|---|
| Telstra Business Smart Modem | **automatic 4G backup built in**; A$288 once-off, or included on 24-month bundles | [X, Telstra critical information summaries via search snippet] |
| Aussie Broadband 4G backup | A$0 or A$10 a month extra, capped at 25/5 Mbps, A$330 modem; activated by phone request, not clearly automatic | [F https://www.aussiebroadband.com.au/business/mobile/4g-backup/] [F https://www.whistleout.com.au/Broadband/News/Aussie-Broadband-4G-backup-for-NBN-if-you-call] |
| Data-only 4G SIM | A$40–60 a month | [F https://grampianstars.pages.dev/blog/2026-02-24-ballarat-business-internet-backup] (an IT provider's blog) |
| Starlink business | about A$150 a month | [F, same page] |
| Dual-WAN routers (UniFi, DrayTek, Teltonika) | a one-off hardware cost | [X] not priced in this pass |

**Code reused:**
- the box, `.deb`, enrolment and uplink;
- the heartbeat (outage detection already happens in the cloud);
- the scheduler, PDF reports and multi-site views.

**New (estimate 4–6 weeks):**
- multi-WAN policy routing and link health checks in the gateway;
- 4G or USB modem support;
- the box sitting inline as the router, which the current pilots avoid;
- per-site outage reports.

Reuse is moderate. Failover is mostly new code, and it is the part the telco gives away.

**Risks:**
- **Crowded by the telco's own modem.** The first objection will be "my Telstra modem already
  does that". Most of the value left over is the outage log and someone to call.
- The box has to sit inline as the router, which raises support load for a sole trader.
- Selling direct to clinics conflicts with the MSP channel. Selling through MSPs means competing
  with the routers MSPs already fit.

**How to validate by 29 Dec:**
- Use the father's network to ask 10 clinics: "hours offline in the last 12 months, what it cost
  you, and does your modem fail over automatically?"
- **Continue** only if 3 or more of 10 have no automatic backup **and** lost over A$1k last
  year. Otherwise the problem is already solved for them.
- This costs nothing to test and can run in parallel with option 1.

---

### Option 3: an app-usage and site-uptime QBR report for MSPs (option 1 without the prospecting)

**Pitch:** "A per-site page for your QBR: which apps they use, which ones overlap, and how often their internet dropped."

**Money or time argument:**
- SaaS waste figures are vendor-sourced and not sized for small offices:
  - 53% of licences unused (Productiv) [F
    https://www.helpnetsecurity.com/2023/07/04/saas-spend-management/];
  - 34% of software budget wasted at 100–200 staff, average US$89k (Cledara, 200+ firms) [F
    https://cledara.com/blog/2025-software-spend-report].
- A small clinic's software spend is small: Cliniko is about A$45 per practitioner a month, and
  Best Practice Bp Allied about A$521 a year [F
  https://www.precisionit.com.au/blog/practice-management-software-australia-pricing-and-it-requirements].
  So the waste a clinic could recover is in the hundreds of dollars a year, not thousands
  (inference).
- The time argument is QBR prep (1–4 hours per client per review [X]). The box would cover only
  part of it.

**Competitors and prices:**
- **SaaS Alerts is free inside Kaseya 365 User** [F
  https://www.kaseya.com/press-release/kaseya-continues-driving-msp-profitability-and-efficiency-with-launch-of-kaseya-365-user-at-dattocon-miami/].
- Augmentt has no published per-seat price; its page gives an estimated US$250 a month entry
  [F https://augmentt.com/pricing].
- Auvik SaaS Management uses a browser extension, an agent and SSO data, with no list price [F
  https://www.auvik.com/?p=13].
- ScalePad is US$25 per client a month [F]; Strategy Overview is from US$75 a month [F].
- No MSP-focused DNS-only discovery product was found [F, gatherer's scan].

**Reuse and new:** highest reuse of all the options (resolver, catalogue pattern, multi-site
views, PDF). New work is the app catalogue and the report, about 2–3 weeks.

**Risks:**
- The money is too small per small client.
- The API-based tools see licences and seats; DNS only sees traffic.
- It is blind to remote workers.
- The MSP's QBR tool may already be "good enough".
- On its own it is a feature, not a product. Its best use is as the after-sale half of option 1.

**Validate:** the same calls as option 1, with one question: "Would you pay A$5–10 per site a
month to add this page to your QBR?"

---

### Option 4: remote-session time capture for MSP billing

**Money argument (weak):**
- Leakage of "3–10% of total revenue" is Gradient's informal estimate [F
  https://www.meetgradient.com/resources/are-you-leaking-revenue].
- Rev.io's "5–15%" is hypothetical [F
  https://www.rev.io/blog/the-100k-leakage-problem-hiding-in-your-field-service-operation].
- On r/msp (via mirror), an owner billed 20 hours a month on estimates against 30–40 actual [F
  https://reddit.sentinel-team.org/posts/1q01os8/snapshots/2026-01-03T02%3A41%3A00.128661Z].

**Why it's weak:**
- AU MSPs mostly price per user (A$119–264 a month) with hourly overage [F, Stanfield]. On
  flat-fee work, unlogged time is a cost, not lost billing.
- Some remote tools already push session time into the PSA:
  - BeyondTrust–Autotask and GoTo–ConnectWise [X];
  - Datto Web Remote has a manual stopwatch [F
    https://rmm.datto.com/help/en/Content/3NEWUI/WebRemote/AutotaskTicket.htm].
- The box sees that a control channel was in use at a site (D52 tags). It cannot see which
  technician or which ticket, which is the part billing needs.

**Reuse:** channel tags. **New:** PSA integrations (ConnectWise, Autotask, HaloPSA), which is
months of API work for a weak attribution.

**Verdict:** don't pursue.

---

### Option 5: compliance or insurance evidence, and premium cuts (weak and kill)

- **Premium cuts: kill.**
  - No named Australian insurer publishes a discount for a control.
  - The 15–40% figures come from consultants who sell assessments [F
    https://www.jasco.net.au/insights/what-is-essential-eight-compliance-for-small-business]
    [F https://netcomp.com.au/blog/how-brisbane-smes-can-reduce-cyber-insurance-premiums-in-2026/].
  - The only numbered discount is tied to buying Sophos MDR (33% off), placed through a US
    insurer [F
    https://www.sophos.com/en-us/blog/cysurance-announces-discounted-cyber-insurance-program-for-sophos-customers-in-australia].
  - A typical small business pays about A$1,200 a year [F
    https://www.upcover.com/blog/how-much-does-cyber-insurance-cost]. Even a 10% saving is
    A$120.
  - Fewer than 4% of small businesses hold cover [F
    https://www.insurancebusinessmag.com/au/news/cyber/cyber-insurance-uptake-drops-below-4-despite-years-of-rate-cuts-595794.aspx].
- **Evidence automation: weak.**
  - An insurance form takes "a few hours" [F https://www.smileit.com.au/?p=3450].
  - Evidence-heavy forms are uncommon: r/msp via mirror says they come mostly from mid-market
    or prior-claim clients [F
    https://reddit.sentinel-team.org/posts/1s1e3ay/snapshots/2026-03-23T20%3A10%3A55.385444Z].
  - Most items are endpoint or Microsoft 365 facts a site box cannot see (MFA, patching,
    backups, macros).
  - Essential Eight assessments cost A$5k–15k [F
    https://innitor-com-au.pages.dev/blog/essential-eight-assessment-cost-australia], but the
    work is consulting, not something this box produces.
- Under the amended brief this is also security-led, so it is out on both counts.

### Option 6: DNS filtering, bandwidth or productivity reporting (kill)

- Prices:
  - DNSFilter US$1.00–2.50 per user a month [F https://dnsfilter.com/pricing];
  - WebTitan's MSP price is US$0.40 per user [F, a competitor's page];
  - NextDNS business A$29.90 a month per 50 staff [F https://nextdns.io/pricing];
  - free from Quad9, Cloudflare and UniFi [X];
  - built into N-able's RMM [F].
- The only small-business productivity figure is a promotional release from 2010 [F].
- Per-employee browsing reports need 14 days' written notice in NSW [F
  https://sprintlaw.com.au/articles/workplace-surveillance-act-2005-nsw-explained/].
- A newcomer wins nothing here.

### Option 7: kill it

If by 29 Dec fewer than 2 MSPs will pay for the option 1 report, and fewer than 3 of 10 clinics
show an unsolved outage problem, **stop**. The evidence then says the box's two real abilities
(seeing DNS at a site, switching traffic) are sold cheaper, or given away, by:
- telcos (failover);
- DNS filters (visibility);
- RMM and PSA vendors (QBR data, time);
- assessment tools (prospecting).

The biggest proven MSP pains found were:
- billing reconciliation (Gradient [F https://www.meetgradient.com/synthesize-billing]);
- QBR prep (ScalePad, Strategy Overview [F]).

Both are solved by software that integrates with the PSA and needs no box at all. A pivot there
would reuse almost none of this code, and those markets are crowded with funded vendors. Keep
the repo as a portfolio piece and spend nothing more.

---

## 3. Gaps in this research

- No independent data on how much assessments lift MSP close rates; only vendor claims [X].
- No measured Australian clinic cost per hour of internet outage.
- Telstra's business 4G backup terms (speed cap, monthly charge) come from search snippets only.
- No r/msp quotes on prospecting tools or on Domotz and Auvik pricing; Reddit was not reachable.
- AUD prices are rare. Most competitor prices are USD or EUR list prices, and many are
  quote-only.
