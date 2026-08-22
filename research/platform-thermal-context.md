# Platform thermal context — PH317-51 / Helios 300 (2017)

**Question:** Is the technical failure the i7-7700HQ silicon, or Acer’s platform?

**Short answer:** The CPU is a normal hot 45 W mobile part. The **practical failure** that creates the need for adaptive fan control and native Turbo recovery is primarily **Acer’s cooling layout, Auto fan policy, and software surface**, amplified by age (paste/dust) and, on the reference machine, an artificial ThrottleStop 28× cap.

## Layer model

```text
┌─────────────────────────────────────────────────────────┐
│  Layer 4 — Third-party software (ThrottleStop, etc.)    │
│  Optional; can impose ratio caps / vulnerable drivers   │
├─────────────────────────────────────────────────────────┤
│  Layer 3 — PredatorSense / WMI AcerGamingFunction       │
│  Auto curve conservative; Max/CoolBoost available       │
├─────────────────────────────────────────────────────────┤
│  Layer 2 — Acer mechanical design                       │
│  Shared heatpipes, dual fans, often one-sided exhaust   │
├─────────────────────────────────────────────────────────┤
│  Layer 1 — Intel Core i7-7700HQ                         │
│  45 W TDP, turbo to 3.8 GHz, Tj max ~100 °C             │
└─────────────────────────────────────────────────────────┘
```

| Layer | Defect? | Role |
|-------|---------|------|
| Intel 7700HQ | No (by design) | Dense Kaby Lake-H; any thin chassis runs warm under sustained load |
| Acer cooling | **Yes — primary** | Shared CPU/GPU thermal path; limited sustained headroom |
| Acer fan policy | **Yes — amplifies** | Auto reacts late; community fix was Max + undervolt |
| ThrottleStop (reference PC) | **Yes — local** | 28× all-core ceiling; `ThrottleStop.sys` CVE-2025-7771 class |

## Intel context (not the “bug”)

- TDP **45 W**; base 2.8 GHz; turbo up to **3.8 GHz** (1-core); stock multi-core ratios fall with active cores (38/36/35/34× class envelope documented in this project’s native Turbo plan).
- Mobile H-series chips of this era routinely sit **85–95 °C** in gaming laptops when cooling is average.
- Better-cooled chassis of the same generation held lower package temps at similar clocks; the silicon is not uniquely defective.

## Acer platform findings (ecosystem)

Synthesized from Acer Community, Notebookcheck, LaptopMedia, TechRadar, and regional reviews (EN/DE/PL/RO/ES). Source index: [forum-sources.md](forum-sources.md).

### Mechanical / thermal design

- Dual-fan systems that still **share heatpipes** between CPU and GPU; combined load collapses sustained clocks.
- 2017/2018-class units often exhaust primarily from **one side**; opposite “vent” can be cosmetic — keyboard deck hotspots (left/center).
- 17-inch PH317 cooling described as **closely related to the 15-inch** design in at least one teardown-oriented review, limiting the benefit of the larger chassis.
- Factory paste durability commonly cited at **6–12 months** before noticeable rise; dust clogging is a recurring “sudden shutdown / high temp” root cause years later.

### Control policy

- PredatorSense: **Auto / Max / Custom** + CoolBoost (raises max fan RPM).
- Community FAQ (Helios era): ~**90–96 °C** → Turbo cut; ~**97–100 °C** → serious throttling; recommended actions include **fans Max**, undervolt, cooling pad, repaste.
- Auto is widely described as insufficient for sustained gaming without manual Max/CoolBoost.
- Fan control effectively gated through OEM software for many users; when PredatorSense fails, alternatives are limited without WMI/EC knowledge.

### Software culture

- For years the dominant “fix” path was **ThrottleStop undervolt**, not an Acer BIOS that steepened Auto curves.
- That culture collides with modern security: VBS/HVCI and vulnerable kernel helpers (`ThrottleStop.sys`).

## Reference machine (this repository)

Distinct from generic forum averages:

1. **ThrottleStop profile** forced **28×** despite stock ratio table capability.
2. **Fan Auto** reacted late under the project’s FMA workload; **Max** delivered −12 °C peak and +8.5 % throughput (same 28× ceiling) — see `evidence/benchmarks/2026-08-21-fan-auto-vs-max.json`.
3. **CRUWBlocker** residual storage filter (driver hygiene), orthogonal to thermals but part of “platform health.”
4. BIOS **V1.22**, Windows 11 build **26200**, WMI class **`AcerGamingFunction`** validated.

Project response (by design):

- Legitimate **WMI** fan writes + fail-closed watchdog (not EC poking).
- **Native** Turbo / power-plan path without depending on `ThrottleStop.sys`.
- Evidence-first claims; no multi-model compatibility assertion.

## What this is *not*

- Not proof that every PH317-51 is broken out of the box.
- Not a claim that undervolt is required (this project’s phase-1 non-goal).
- Not authority to run these scripts on other Predator/Nitro SKUs without re-validation.

## Implications for engineering priority

1. Fan policy and readback (already core) address Acer’s **control** gap.
2. Hardware baseline (clean/repaste) addresses **mechanical aging**.
3. Native Turbo addresses **local software damage**, not Intel stock limits.
4. Custom % / telemetry / lifecycle issues refine the same platform story — they do not invent a new CPU defect.
