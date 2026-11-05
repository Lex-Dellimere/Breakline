# Mettle for robots, drones and embedded: what could sell

Desk research, 6 Nov 2026. Eight narrow web gatherers (Haiku), plus my own reading of the Mettle
repo (`~/Projects/mettle/Mettle`, v0.18.0, read only). Nobody was contacted, nothing was signed up
for, nothing under `~/Projects/mettle` was changed.

## Source tags

- **[F]** A gatherer opened the page and reported it (URL given). Gatherer output is a small-model
  summary, so re-open any page before quoting it to a customer.
- **[X]** Search snippet only, or my own inference or arithmetic (marked "inference").
- **[R]** Read in the Mettle repo myself (file given).
- **Every Mettle and Potentia performance number is the project's own measurement. No third party
  has reproduced any of them.** The headline LLM numbers were measured against llama.cpp (via LM
  Studio) on a discrete RTX 5060 Ti on a desktop, not on any edge device [R `README.md`].
- Currency: US$1 ≈ A$1.50 is my working assumption [X].

## The answer in one paragraph

The only option with a real money argument is **on-device LLM/VLM inference for Jetson-based robots
and drones, sold first as a fixed-price "fit test" and only later as a runtime licence**. The money
is in hardware tiers. After NVIDIA's July 2026 price rise, an AGX Orin 64GB module costs US$2,999
and an Orin NX 16GB costs US$999 [F]. An 8B model at INT4 already needs about 7.2 GB on NVIDIA's own
runtime [F], right at the edge of the 8GB Orin Nano. So every GB saved can move a product down a
tier, worth up to US$2,000 a unit. But that argument is unproven for Mettle in three ways:
- Potentia has never run on a Jetson, or on any ARM GPU [R `docs/gpu-architecture.md`].
- Its headline wins are against llama.cpp, while the incumbent on Jetson is NVIDIA's free TensorRT
  Edge-LLM, which already beats llama.cpp there [F].
- Its RAM headline probably comes from a discrete-GPU effect, a host copy of the weights, which
  does not exist on Jetson's unified memory [X, inference].

So spend the next 4–6 weeks on two cheap tests: will Jetson teams pay A$2,500 for a fit test, and
does Potentia on an Orin beat TensorRT Edge-LLM on memory? The runner-up is plain edge-AI and CUDA
contracting, with Mettle as the calling card. It pays soonest and fits a job on the side. The other
three ideas, listed below, are weak or dead:
- hot-patching fleets;
- certification evidence;
- a microcontroller backend.

If both tests fail by week 6, take the kill option at the end.

---

## 1. Questions, hypotheses, and what would confirm or kill each

| # | Hypothesis | Confirm if | Kill if | Result |
|---|---|---|---|---|
| H1 | Jetson robot/drone teams will pay for lower RAM, energy and latency in on-device LLM/VLM inference | RAM is a felt limit; the free stacks leave a gap; someone pays for runtimes or optimisation | Free NVIDIA tooling already closes the gap; nobody pays per device | **Alive but unproven.** RAM is the tier boundary and tiers cost thousands. But TRT Edge-LLM is free and strong, and Potentia has no Jetson numbers |
| H1b | Mettle's PTX path matters on Jetson's integrated GPU | Mettle targets Orin (sm_87) and Thor (sm_110) | Profiles and fast paths are Blackwell/Hopper-only | **Partly.** Stable WMMA covers sm_80+, so Orin is reachable. TMA/FP8/FP4 fast paths need sm_90+/sm_120, and sm_110 is not a listed profile [R] |
| H2 | Fleets will pay to hot-patch robot/drone code without a reboot | Downtime costs are measured; someone pays for app-level hot reload | OTA is cheap and reboots are tolerated; safety change control objects | **Dead for now.** No payer found, OTA costs US$0.16–1.20/device/month, and `mettle live` does not run on AArch64 |
| H3 | Compiler rules plus `--explain` sell as certification evidence | A cheaper path than tool qualification exists for a new compiler; drone regulations ask for it | Qualification is required and costly; the customer's code is C/C++ | **Dead as a product.** Customers would have to rewrite in Mettle. Qualified compilers sell at about €240/user/yr (Ferrocene) |
| H4 | A Cortex-M/RISC-V backend opens flight-controller money | Paid demand for a new MCU language | Compilers are cheap or free, the firmware is C/C++, adoption takes a decade | **Kill.** Months of backend work and no buyer |
| H5 | Australian defence/drone funding can carry a solo founder | A program open to a sole trader with no co-funding | Programs need a Pty Ltd, co-funding or DISP | **Not reachable now.** Everything credible needs a company, co-funding or DISP |
| H6 (added) | The skills behind Mettle sell as services right away | Published rates for CUDA/Jetson work; AU contract rates | No rates; no demand | **Alive.** US$155/h specialist rate; A$1,000–1,200/day senior embedded contracts |

---

## 2. What the evidence says

### Jetson inference today (H1, H1b)

**The stacks are all free.** NVIDIA's Jetson AI Lab tells people to use Ollama to start and vLLM
for production [F https://www.jetson-ai-lab.com/tutorials/genai-on-jetson-llms-vlms/]. TensorRT
Edge-LLM supports Thor and targets Orin at FP16/INT8/INT4, under Apache-2.0
[F https://nvidia.github.io/TensorRT-Edge-LLM/latest/overview.html,
https://github.com/NVIDIA/TensorRT-Edge-LLM]. llama.cpp and Ollama are MIT; MLC-LLM, vLLM and
TensorRT-LLM are Apache-2.0 [F, licence files on GitHub].

**The incumbent already beats llama.cpp on Jetson.** A community benchmark ran Cosmos-Reason2-2B
on an Orin Nano Super at MAXN_SUPER [F https://github.com/hokwangchoi/jetson-orin-nano-benchmarks]:

| Runtime | Decode | Time to first token | Peak memory |
|---|---|---|---|
| llama.cpp Q4_K_M | 38 tok/s | 33 ms | not reported |
| vLLM W4A16 | 56 tok/s | 61 ms | 6.9 GB |
| TRT Edge-LLM W4A16 | 60 tok/s | 29 ms | 4.3 GB |

Potentia's 1.7–2.4x time-to-first-token and 1.07–1.41x decode wins are against llama.cpp
[R `README.md`], so they say nothing yet about TRT Edge-LLM.

**Memory footprints, from NVIDIA's Edge-LLM benchmarks** (INT4 AWQ, batch 1)
[F https://nvidia.github.io/TensorRT-Edge-LLM/0.11.1/user_guide/performance/performance-benchmarks.html]:

| Module | Model | Memory | Decode |
|---|---|---|---|
| AGX Orin 64GB | Qwen3-8B | 7,199 MB | 32.2 tok/s |
| AGX Orin 64GB | Qwen3-VL-8B | 9,004 MB | 32.1 tok/s |
| Orin NX 16GB | Qwen3-8B | 7,167 MB | 18.4 tok/s |
| Orin Nano 8GB | Qwen3-1.7B | 2,992 MB | 36.5 tok/s |
| Orin Nano 8GB | Qwen3-VL-2B | 4,486 MB | 36.1 tok/s |

JetPack itself uses about 0.8 GiB at boot on 7.2 and about 1.4 GiB on 6.2
[F https://wiki.seeedstudio.com/jetpack_7_2_memory_optimization_deep_dive/].
- Inference: an 8B text model at about 7.2 GB, plus an OS, does not fit an 8 GB Orin Nano, and an
  8B VLM at about 9 GB certainly does not. 4-bit weights for 8B are about 4.5–5 GB, so roughly
  2–4 GB of each footprint is runtime overhead. **That overhead is the only RAM Mettle could win
  back on Jetson** [X].

**Throughput on Thor** (vLLM, concurrency 1)
[F https://developer.nvidia.com/embedded/jetson-nano-dl-inference-benchmarks]:
- Llama 3.1 8B: 41.3 tok/s.
- Qwen3-30B-A3B: 61 tok/s.
- Llama 3.3 70B: 4.7 tok/s.

**RAM pain on Jetson is real, but the reported failures are platform bugs.** The Orin Nano 8GB
reports are allocation failures from memory fragmentation, not models too big for the board.
"Unable to allocate CUDA0 buffer" appeared with about 3.8 GB free but only a 4 MB largest block.
NVIDIA staff called it a known regression in r36.4.7, fixed in JetPack 6.2.2
[F https://forums.developer.nvidia.com/t/ollama-llm-inference-problems-on-jetson-orin-nano-cuda-memory-allocation-failure-and-cpu-memory-error/363574,
https://forums.developer.nvidia.com/t/cuda0-buffer-error/356432]. No source confirms that
llama.cpp double-counts memory (page cache plus CUDA) on Jetson [F, searched; not found].

**Hardware, power and prices.**

| Module | Power | Memory | Price |
|---|---|---|---|
| Orin Nano 8GB | 7/15/25 W | 8 GB, 102 GB/s | Super dev kit US$399 |
| Orin NX 16GB | 10–25 W (NVIDIA's own table also shows 40 W) | 16 GB | US$999 |
| AGX Orin 64GB | 15–60 W | 64 GB | US$2,999 (dev kit US$3,499) |
| Thor | 40–130 W | 128 GB | T5000 module US$4,999, dev kit US$5,499 |

- Power and memory for Orin: [F https://www.nvidia.com/en-us/autonomous-machines/embedded-systems/jetson-orin/].
  For Thor: [F https://www.nvidia.com/en-us/autonomous-machines/embedded-systems/jetson-thor/].
- Prices are after the July 2026 rise of up to 101%. Before it, the same four were US$249, US$599,
  US$1,599 and the Thor dev kit US$3,499
  [F https://cnx-software.com/2026/07/22/nvidia-increases-the-price-of-jetson-modules-and-devkits-by-up-to-101/].
  NVIDIA's store was not checked.
- No price was found for the Orin Nano 8GB module alone.

**Compute capability.** Orin is sm_87 [F https://developer.nvidia.com/cuda-gpus]. Thor's T5000 and
T4000 are listed at 11.0, so sm_110 (it was sm_101 before CUDA 13) [F same page; X rename].

**What Mettle actually has for this** [R]:
- Its primary GPU profile is GB10, the DGX Spark chip (`sm_121a`), but execution on GB10 is "not
  yet recorded" [R `docs/gpu-architecture.md`].
- Device evidence exists only on compute 12.0 (the RTX 5060 Ti).
- Stable WMMA covers sm_80+, which includes Orin in principle. TMA, FP8 and FP4 need sm_90+.
- There is no Jetson mention anywhere in the docs.
- AArch64 host code is CI-built, and its full fixture set has only run under QEMU
  [R `docs/bare-metal.md`].
- Potentia is Systm's product, and Systm is "the company that develops Mettle"
  [R `website/index.html`]. Confirm that the user can sell or licence it.

### Who buys, and who already sells (H1)

**Teams running models on-board.**
- Wing, Alphabet's delivery drones, uses the Orin Nano Super. Matic Robots is adopting Orin Nano 2
  [F https://www.electronicdesign.com/technologies/embedded/product/55401539/electronic-design-nvidias-new-nano-jetson-brings-llms-to-robotics].
- Skydio X10's spec page lists a Jetson Orin SoC [F https://www.skydio.com/x10/technical-specs].
- Unitree G1 uses an Orin NX [X]. Figure and Atlas are moving to Thor [X].
- Shield AI and Anduril run inference on-board, hardware not named [X].
- No source puts a share on Jetson against Qualcomm or NXP.

**Drone companion computers are split, and the non-Jetson ones have no CUDA.**
- ModalAI VOXL 2 is Qualcomm QRB5165, from about US$1,249 [X].
- Auterion Skynode S is a quad Cortex-A53 with a 2.3 TOPS NPU and 4 GB
  [F https://docs.auterion.com/hardware-integration/skynode-s/datasheet].
- Mettle's PTX path is worthless on both. Its AArch64 CPU path would run, but without GPU kernels
  there is no speed story [X, inference].

**Vendors in the same space.**
- None found publishes a per-device runtime licence price [F/X, searched].
- Edge Impulse is free for internal production up to 1,000 units, with custom enterprise quotes
  [F https://edgeimpulse.com/pricing]. Vendr's median buyer pays US$12.9k/yr [X].
- Picovoice picoLLM: US$6,000/yr for startups, from US$30,000/yr enterprise [X, page empty].
- Embedl raised €5.5M and names Bosch and Kodiak Robotics as customers
  [F https://tech.eu/2025/06/18/embedl-raises-eur55m-to-boost-ai-efficiency-in-embedded-systems/].
- Nota AI's 2024 revenue was US$5.89M, after years in this exact business
  [F https://blog.nota.ai/newsroom/nota-ai-kosdaq-listing-global-expansion].
- Latent AI, Clika and Plumerai are funded but publish no prices [F/X].

**The exits went to the chip makers.**
- Deci went to NVIDIA for about US$300M [F https://ats.org/ats-news/nvidia-to-acquire-deci-for-300-million/].
- OctoAI went to NVIDIA for about US$250M [F https://getcoai.com/news/nvidia-buys-octoai-to-strengthen-enterprise-ai-dominance].
- Neural Magic went to Red Hat [F https://www.constellationr.com/insights/news/red-hat-acquires-neural-magic].
- Modular went to Qualcomm [F https://www.themachinemaker.com/news/qualcomm-completes-acquisition-of-modular-to-strengthen-ai-software/].
- Read: inference optimisation is a technology people buy companies for, not a product with large
  standalone revenue [X, inference].

### Services rates (H6)

- RidgeRun, a Jetson specialist, charges US$155/h for professional support
  [F https://developer.ridgerun.com/wiki/index.php/RidgeRun_Professional_Services].
- A Jetson feasibility study is sold as 2–3 weeks ending in a go/no-go report, priced on a call
  [F https://marketing-edgeai.pages.dev/en/services, an unofficial-looking domain].
- Fiverr Jetson/TensorRT gigs run US$50–600 [X].
- One estimate puts TensorRT pipeline work at 4–8 engineer-weeks per platform generation
  (Fixstars blog) [X].
- In Australia, a senior embedded contract in Sydney paid A$1,000–1,200/day, but it required a
  clearance and Australian citizenship [F https://www.kinexus.com.au/job/senior-embedded-software-engineer-652398].
  The median embedded salary is about A$90k [F https://www.payscale.com/research/AU/Job=Embedded_Software_Engineer/Salary].
- A Seek scan near Brisbane found no Jetson or CUDA roles [F https://au.seek.com/computer-vision-engineer-jobs/in-Rothwell-QLD-4022],
  so the Australian Jetson market is thin.
- Job posts asking for TensorRT average US$180k–307k, mostly NVIDIA roles [F https://inferencejobs.com/salaries/skills/tensorrt].
- NVIDIA Inception is free but needs an incorporated company [F https://www.nvidia.com/en-us/startups/].

### Hot-patching fleets (H2)

**OTA is cheap.**
- Mender: US$34/mo for up to 50 devices, US$291/mo for up to 250 [F https://mender.io/plans/pricing].
- Golioth: US$0.25 per device per month [F https://golioth.io/pricing].
- AWS Greengrass: US$0.16 per device per month [F https://aws.amazon.com/greengrass/pricing/].
- Balena: US$1,439/mo for 110 devices [F https://www.balena.io/pricing].

**Live patching sells only for kernel security fixes.** Canonical Livepatch is bundled into Ubuntu
Pro at US$25–3,400 per machine per year [F https://ubuntu.com/pricing/pro]. KernelCare+ is
US$3.95–5.95 per server per month [F https://tuxcare.com/kernelcare-a-premium-subscription-with-glibc-openssl-patching/].

**Other findings.**
- No evidence anyone pays for application-level hot reload on robots. ROS 2 has none built in [X].
- Downtime-cost figures (US$200–500 per robot-hour) are vendor marketing [X].
- EASA treats software changes to certified equipment as configuration changes [X]. IEC 61508-3
  §7.8 requires a traceable change process [X].
- **And `mettle live` runs on Windows x64 and Linux x64 only**, not AArch64, where every Jetson
  is [R `docs/live.md`].

### Certification evidence (H3)

**When a compiler needs qualification.**
- Under ISO 26262 a compiler is TI2. It drops to TCL1, needing no qualification, only if errors in
  its output are detected with high confidence [F https://www.validas.de/@/page/whey2yempbc8shvv].
- IEC 61508 classes compilers T3, re-qualified for each version [X].
- DO-178C lets a compiler go unqualified when its output is verified by test [X].

**Prices.**
- Ferrocene, Rust qualified to ASIL D and SIL 3 with TÜV SÜD, costs **€25/user/month or
  €240/user/yr** [F https://ferrous-systems.com/blog/ferrocene-24-05-0/]. So even a certified
  compiler sells at commodity prices.
- Parasoft C/C++test starts at US$35/month; qualification kits are enterprise-only
  [F https://www.parasoft.com/products/parasoft-c-ctest/plans-and-pricing/].

**Drones.**
- CASA's AusSORA (AC 101-06) applies from 11 May 2026, and no reference to DO-178C was found [X].
- Blue UAS assesses cybersecurity and NDAA compliance, with no DO-178C-style software level
  [F https://www.diu.mil/latest/blue-uas-to-evolve-to-meet-broader-department-of-defense-needs].

**The blocker that decides it.**
- Mettle has no C frontend [R `docs/c-interop.md`, `docs/mettle-and-libmtlc.md`].
- Rules and `--explain` only see Mettle code. Drone and robot code is C/C++.

### Microcontrollers (H4)

**Commercial compilers cost about €1.5–7k a seat a year, and free tiers are common.**
- Keil MDK Professional: A$287/month [F https://store.arm.com/mdk-6/professional/].
- SEGGER Embedded Studio: €1,480–1,980 [F https://www.segger.com/purchase/pricing/embedded-studio/].
- IAR for Cortex-M: about US$995 at one reseller [X].

**Firmware and languages.**
- ArduPilot runs on STM32 F4/F7/H7 [F https://ardupilot.org/plane/docs/common-autopilots.html].
  PX4 is C++ on NuttX [X]. Neither project has a non-C/C++ effort [X].
- JetBrains 2025 survey: C++ 27%, C 23% [F https://lp.jetbrains.com/the-state-of-embedded-2025].
- AdaCore, the long-run proof of a niche-language business, makes roughly €15–30M a year after
  decades [X].

### Australian funding (H5)

**Needs a company.**
- CSIRO Kick-Start: A$20–60k matched, ACN required [F https://business.gov.au/grants-and-programs/csiro-kickstart].
- Industry Growth Program: companies only, and paused [F https://business.gov.au/grants-and-programs/industry-growth-program].
- R&D Tax Incentive refundable offset: company claimant [X].

**Defence.**
- Defence Industry Development Grants are open year-round; eligibility and co-contribution are
  unverified [X].
- ASCA's Emerging and Disruptive Technologies calls run through AusTender. The persistent-ISR call
  closed 18 May 2026 [X].
- DISP membership is entity-based, with a security officer [X].

**Other routes.**
- No Australian SME drone software challenge was found for 2025–26 [X].
- Anduril Australia and Boeing MQ-28 work through existing SME suppliers, with no open portal
  found [X].

**Read: none of it is reachable as a sole trader with A$300.** Registering a Pty Ltd costs about
A$600 [X, not checked], which is more than the cash on hand.

---

## 3. Product options, ranked

### 1. Jetson "fit test", then a Potentia Edge licence (recommended, conditional)

**Pitch:** "Send us your on-board model and your target Jetson. In two weeks we tell you, with
measurements, whether it fits the cheaper module, and we make it fit if it can."

**Buyer:** engineering leads at robot and drone companies that already run, or want to run, an
LLM, VLM or VLA on a Jetson. Examples are humanoid, delivery, inspection and defence ISR teams.
Most are in the US and EU. Australia is thin [F Seek scan], so the friend's calls must go
offshore or into the few AU drone firms.

**Money and time argument:**
- **Hardware tier.** Orin NX 16GB costs US$999 against US$2,999 for AGX Orin 64GB [F]. Moving down
  one tier saves up to US$2,000 a unit, so US$200k on a 100-unit fleet [X, arithmetic].
- **Where the boundary sits.** An 8B INT4 model needs about 7.2 GB on TRT Edge-LLM and an 8B VLM
  about 9 GB [F], so the 8GB Nano boundary falls exactly on the models people want.
- **Power.** The 8GB Nano runs at 7–25 W against 10–25(40) W for the NX [F]. That is flight time
  on a drone.
- **Engineering time.** Porting and optimising inference is 4–8 engineer-weeks per platform [X].
  At US$155/h [F], that is US$25–50k a team avoids.

**Competitors and prices:**
- The real incumbents are free: TensorRT Edge-LLM, vLLM, llama.cpp, MLC and Ollama [F].
- Paid optimisers mostly quote privately: Embedl, Nota (US$5.9M revenue) [F], Latent AI and Clika.
- Edge Impulse is free up to 1,000 internal units [F].
- Services: RidgeRun at US$155/h [F], and 2–3 week feasibility studies [F].

**What Mettle already has:**
- PTX codegen with no nvcc.
- sm_80+ WMMA, so Orin is reachable in principle.
- AArch64 host codegen and a Linux AArch64 CI build.
- Potentia, with an engine that self-checks GPU output against a CPU reference [R].

**What must be built (my estimates [X]):**

| Work | Estimate |
|---|---|
| Run Potentia natively on Orin (sm_87): AArch64 host on real hardware, unified-memory allocation, an Ampere kernel path without TMA/FP8/FP4, correctness gate | 3–6 weeks |
| Tune decode and prefill against TRT Edge-LLM | 2–4 weeks |
| A Thor (sm_110) profile | 2–4 weeks |
| Packaging as a container plus C ABI or HTTP API, and a licence key | 1–2 weeks |
| **Total to something sellable** | **about 8–14 weeks** |

**Biggest risk.** On unified memory, Potentia may not beat TRT Edge-LLM at all:
- Its RAM headline (8.5–23.5x) is probably host-RAM duplication that does not exist on Jetson
  [X, inference].
- Its speed wins are against llama.cpp, which TRT Edge-LLM already beats by 1.6x on decode on the
  same board [F].
- Second risk: Potentia belongs to Systm [R]. Confirm the user has the right to sell it.
- Third risk: NVIDIA ships the improvement for free next release.

**Validation test (under A$100, 4–6 weeks):**
- **Demand.** The friend calls or emails about 40 teams using Jetson for on-board models, found
  through LinkedIn, Jetson forum posters, Hackster projects and the AU drone firms listed in
  section 2. The offer is a **fixed-price A$2,500 fit test**:
  - the customer gives SSH access to their own Jetson and names a model;
  - the deliverable is peak memory, TTFT, tok/s and watts against TRT Edge-LLM, plus a go/no-go
    for the smaller module.
  - Cost: a domain and a one-page site, about A$30.
- **Engineering, in parallel and on the first borrowed board.** Get one 2B–8B model correct on
  Orin through Potentia and measure it against TRT Edge-LLM on the same quantisation.
- **Pass:** two paid fit tests, or signed letters of intent with hardware access, and Potentia at
  least 20% lower peak memory or TTFT than TRT Edge-LLM.
- Do not buy a dev kit. At US$399 (about A$600) it is twice the cash.

### 2. Edge-AI and CUDA performance contracting, with Mettle as the calling card (runner-up)

**Buyer:** robotics, drone and vision startups with a Jetson or CUDA bottleneck, plus AU firms
hiring embedded contractors.

**Money:**
- Specialist rate US$155/h [F]. AU senior embedded contracts A$1,000–1,200/day [F], although
  cleared roles need citizenship and a clearance.
- One 3-week engagement at A$1,000/day is about A$15k [X, arithmetic].
- It pays in weeks, not quarters, and it can sit alongside a job.

**Competitors:** RidgeRun, Fiverr gigs at US$50–600 [X], Toptal, and Upwork at about US$45/h [X].
The differentiator is a public, reproducible benchmark story, which is exactly what Potentia gives
if it holds up on Jetson.

**What Mettle has:** credibility. A self-written compiler that emits PTX directly is a rare
portfolio piece.

**What must be built:** nothing technical. A one-page offer and two case-study write-ups take
about 1 week.

**Biggest risk:** this is selling hours, not a product. It caps income at time worked, and
low-cost offshore freelancers anchor prices down.

**Validation test (under A$100, 4 weeks):**
- Publish one honest write-up of Potentia against llama.cpp and, if possible, TRT Edge-LLM.
- List a fixed-scope "inference fit test" on Upwork and Contra, and have the friend pitch it to
  20 AU and NZ robotics and vision firms.
- **Pass:** one paid engagement of A$2,000 or more.

### 3. Compiler-enforced rules plus `--explain` as audit evidence (weak)

**Buyer:** in theory, safety and defence software teams that need traceable evidence.

**Money argument:** none that survives contact.
- Their code is C/C++ and Mettle has no C frontend [R].
- A tool-qualified compiler sells for €240 per user per year [F].
- Qualification under ISO 26262 or IEC 61508 costs TÜV assessments and per-version
  re-qualification [F/X].

**Competitors:** Ferrocene; Parasoft from US$35/month [F]; Polyspace, Coverity and CodeSonar,
all quote-only.

**What must be built:** a qualification package, years of it, or a C frontend, many months [X].

**Biggest risk:** no buyer will rewrite flight code in a new language to get a report.

**Validation test (under A$50):** five calls to safety-software leads asking one question: "would
you write new non-flight-critical tooling in a new language if its compiler produced a per-build
evidence report?"
- **Pass:** two say yes and name the report they need. I expect a fail.

### 4. Hot-patching robot and drone fleets (weak)

**Buyer:** fleet operators of AMRs and inspection robots.

**Money argument:** unproven. Downtime figures are vendor marketing [X]. OTA costs
US$0.16–1.20 per device per month [F]. No one pays for application-level hot reload [X].

**What must be built:** `mettle live` on Linux AArch64, which it does not do [R], plus remote
patch delivery, signing and rollback, plus a ROS 2 bridge. That is about 6–10 weeks [X], and the
customer must write in Mettle.

**Biggest risk:** safety change control (IEC 61508-3 §7.8, EASA configuration rules) makes
"change it while it runs" a liability in exactly the regulated markets that pay [X].

**Validation test (under A$50):** ten calls to robot fleet operators asking how often an update
reboot costs them a mission, and what they would pay to avoid it.
- **Pass:** three name a dollar cost per reboot over A$500.

### 5. Cortex-M or RISC-V backend (kill now)

- Compilers sell for €1.5–7k a seat, with free tiers [F].
- Flight firmware is C/C++ on STM32 [F/X].
- Rust took about a decade to get vendor support and still has no vendor-funded MCU toolchain
  outside Ferrocene [X].
- A new backend plus runtime plus HAL is many months of work, for no identified buyer.
- No validation test is worth running. Revisit only if a paying Option 1 customer asks for an MCU
  co-processor target.

**Funding (H5) is an enabler, not a product.** Revisit it only after Option 1 or 2 makes money:
incorporate, then apply to CSIRO Kick-Start and Defence Industry Development Grants, and seek DISP
membership if a defence prime asks.

---

## 4. Kill option

At the end of week 6, kill Mettle as a robotics product if either of these is true:
- **No buyer:** fewer than two teams out of about 40 accept a paid fit test or hand over hardware
  access, and no contracting lead reaches A$2,000.
- **No edge:** on the first real Orin run, Potentia is not at least 20% better than TRT Edge-LLM on
  peak memory or TTFT for the same model and quantisation.

Then stop selling it to robotics. Keep Mettle open-source, and use the compiler and the Potentia
benchmarks as the portfolio that wins a GPU, compiler or edge-inference job. TensorRT-skilled
roles post at US$180k–307k [F https://inferencejobs.com/salaries/skills/tensorrt]. That job is
probably the income anyway, so this is a real outcome, not a consolation.

## 5. What would prove this wrong

- **Optimistic.** Potentia on Orin fits an 8B VLM into the 8GB Nano at usable speed (above
  15 tok/s, with OS headroom). The per-unit tier saving is then real, and a per-device licence of
  US$50–200 against a US$2,000 saving becomes an easy sale. A licence would outrank services.
- **Pessimistic.** Jetson teams say memory is not their limit (latency, the vision pipeline or
  integration is), or they are already on TRT Edge-LLM and happy. Option 1 then dies regardless
  of benchmarks.
