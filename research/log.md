# Research log

Append-only. Newest entries at the top.

## 2026-08-24 — Fans at max on resume; undervolt verdicts

- **Fan incident closed.** "Fans at 100 % after the restart" was this project's
  own fail-closed startup hold, not a thermal or hardware fault. Overnight sleep
  left the heartbeat stale by 32 646 s; the watchdog restarted the primary and
  the controller entered `startupMaxHold`. Released cleanly after 3 min 30 s on
  `startup_max_released_on_verified_cool`. Machine was 41–60 °C throughout.
  Root cause of the *duration*: the `releaseCpuLoadPct: 40` term kept resetting
  the cool counter against the Windows resume burst (47 % load). Written up in
  `fan-max-on-resume-2026-08-24.md`; a narrow policy fix is proposed, not made.
- **CPU undervolt proven dead.** -99.6 mV is configured on core and cache and
  never reaches the silicon: mean VID at a fixed 28x is flat (0.9213 → 0.9356 V,
  14 mV spread) across a month spanning the change, where a working offset would
  step ~100 mV. Cause is the CVE-2019-11157 microcode mitigation making MSR
  `0x150` a silent no-op. Not fixable in software. ThrottleStop retained as a
  logger and for multiplier caps only.
- **GPU undervolt proven a regression.** -9.2 % mean SM clock, +1.9 W mean power,
  power-capped 64 % → 78.8 % of the time, and thermal cap 0 % in *both* runs —
  the card was never thermally limited. The -3 °C is the signature of a slower
  card, not efficiency. Revert to stock V/F curve.
- Both verdicts in `undervolt-effectiveness-2026-08-24.md`. Net: the fan overlay
  is now the only demonstrated lever on this hardware.
- Added `docs/handoff.md` as the state-of-play entry point.

## 2026-08-22 — Research index categories (Option A)

- Grouped notes in `research/README.md` under Platform, Silicon, Ecosystem, Meta.
- Files remain flat; no path moves.

## 2026-08-22 — Gap fill: silicon, PROCHOT, evidence analysis

- Compared full conversation topics to existing `research/` set.
- **Missing prose added:**
  - `cpu-gpu-silicon-notes.md` — turbo bins 38/36/34, cTDP 35 W, PL/Tau, 1060 ~80 W TGP, Optimus, adapter ceiling, limit stack order
  - `prochot-and-tcc-offset.md` — PROCHOT vs BD PROCHOT vs Tcc offset, MSRs, Helios notes, read-only project posture
  - `evidence-benchmarks-analysis.md` — structured read of Auto vs Max + recovery JSON vs controller config
  - `conversation-coverage-2026-08-22.md` — coverage matrix
- Already present (unchanged intent): platform thermal, cross-vendor, GPU UV, forums, repo health.

## 2026-08-22 — GPU thermal role and undervolt

- Question: is there a ThrottleStop-like path for the GTX 1060, and what does UV improve?
- Conclusion: Afterburner V/F curve + power limit are the community tools; goal is same/stable FPS at lower watts/heat; shared heatpipes can cool CPU indirectly under gaming. Not for SYSTEM fan stack.
- Local evidence still CPU-FMA-only; need 3D workload telemetry before claiming GPU is the dominant heat source on this unit.
- Captured in `gpu-thermal-and-undervolt.md`. Tracker issue opened for evidence + optional operator UV posture.

## 2026-08-22 — Cross-vendor control landscape

- Question: CPU/GPU behaviour and solutions on other brands; are we missing an approach?
- Conclusion: heat is genre-wide; **PH317-51 bottleneck remains Acer platform policy**. Solution schools are (1) official WMI/ACPI (G-Helper, LLT, Acer-P-Helper, us) vs (2) EC poke (NBFC, WinRing0). No better public stack for this SKU with fail-closed + evidence + native turbo.
- Borrow as product ideas only: composite AC/DC profiles, predictive dT/dt, Cooler-Boost-style MAX overlay, GPU telemetry — stay on WMI.
- Captured in `cross-vendor-control-landscape.md`.

## 2026-08-22 — Platform vs micro; multi-language forum sweep

- Question: is the need for this project the 7700HQ or Acer?
- Conclusion: silicon is expected-hot H-series; **Acer cooling + Auto fan policy** are the platform drivers; reference machine adds ThrottleStop 28× and aging hardware.
- Captured in `platform-thermal-context.md` + `forum-sources.md`.
- Languages touched: EN (Acer Community, TechRadar, LaptopMedia), DE (Acer Community), PL (Notebookcheck/PurePC), RO (mygarage), ES (Geeknetic).
- Local evidence already on main: Auto vs Max FMA JSON under `evidence/benchmarks/`.

## 2026-08-22 — Repo health pass

- Written `repo-health-2026-08-22.md`: strengths (evidence, fail-closed, docs, security posture) and friction (CRUW monolith size, fan modularization not cut over, issue backlog, docs discoverability, branch `refactor/fan-modules` not merged).
