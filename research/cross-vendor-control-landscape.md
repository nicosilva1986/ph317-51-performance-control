# Cross-vendor CPU/GPU control landscape

**Date:** 2026-08-22  
**Question:** Outside Acer, how do other brands and open-source projects manage laptop CPU/GPU thermals and fans — and are we missing a better approach?

**Short answer:** Heat under sustained load is a **genre** problem (H-series + shared coolers). The **practical fix on this PH317-51** remains Acer’s cooling + Auto policy (see [platform-thermal-context.md](platform-thermal-context.md)). What is new here is a map of **solution architectures** and product ideas worth copying without leaving the official WMI path.

## Genre vs brand

| Layer | Genre (all gaming laptops) | Brand-specific on PH317-51 |
|-------|----------------------------|----------------------------|
| Silicon | 45 W-class CPUs run hot; GPU has TGP limits | i7-7700HQ + GTX 1060 are normal for 2017 |
| Mechanical | Shared heatpipes, dual fans, thin chassis | Acer layout + aging paste/dust on reference unit |
| Firmware policy | Quiet / Balanced / Turbo modes | Auto reacts late; Max helps (local evidence) |
| Software surface | OEM app or WMI/ACPI or EC poke | `AcerGamingFunction` is usable and reversible |
| Local damage | Optional third-party MSR tools | ThrottleStop 28× + vulnerable `ThrottleStop.sys` |

**Do not re-open “is it Acer?” every sprint.** Platform context is settled; this doc is about **control methods**.

## Two schools of control

```text
                    ┌── EC register write (NBFC, WinRing0, many Legion tools)
Firmware fans ──────┤
                    └── OEM WMI / ACPI surface (G-Helper, LLT, Acer-P-Helper, this repo)

Power / Turbo ──────┬── MSR / vulnerable kernel helper (ThrottleStop)
                    └── Windows power plan + Intel stock turbo (native-turbo-plan)
```

| School | Mechanism | Pros | Cons |
|--------|-----------|------|------|
| **Official surface** | WMI/ACPI methods the OEM software uses | Reversible, no EC fight, aligns with BIOS | Feature set limited to what firmware exposes |
| **EC poke** | Direct embedded-controller registers | Fine-grained curves on some models | Dual writers, model-fragile, often needs WinRing0-class drivers |

This project stays in **official surface** for fans and **native Windows/Intel** for turbo. That matches the strongest open-source replacements on ASUS/Lenovo, not the Helios forum NBFC path.

## Representative projects

### Official-surface (preferred school)

| Project | Brand | Notes |
|---------|-------|-------|
| [G-Helper](https://github.com/seerge/g-helper) | ASUS | Lightweight Armoury Crate replacement; same ACPI endpoints; performance modes; fan curves **programmed into BIOS modes** (not a desktop-style PWM loop); GPU Eco/MUX where supported |
| [Lenovo Legion Toolkit](https://github.com/LenovoLegionToolkit-Team/LenovoLegionToolkit) | Lenovo | Replaces Vantage/Legion Zone; power modes; Custom mode (PL + fans on newer gens) |
| LLT CustomFanCurve plugin | Lenovo | Predictive **dT/dt**, EMA/hysteresis, safety full-speed, asymmetric step-down |
| [YAMDCC](https://github.com/bca009/yamdcc) | MSI | Lightweight MSI Center alternative; profiles + Cooler Boost |
| [Acer-P-Helper](https://github.com/supesonly/Acer-P-Helper) | Acer Predator | Tray app over **`AcerGamingFunction`** — same class as this repo; simpler product (modes/UI), not adaptive fail-closed evidence stack |
| **This repository** | PH317-51 | WMI Auto/Max (+ Custom lab); adaptive policy; watchdog fail-closed; evidence; native turbo plan; CRUW hygiene |

### EC / dual-writer school (documented, not adopted)

| Project | Notes |
|---------|-------|
| [NoteBook FanControl (NBFC)](https://github.com/hirschmann/nbfc) / [nbfc-linux](https://github.com/nbfc-linux/nbfc-linux) | Cross-vendor EC configs; community profiles exist for some Helios units |
| Helios forum NBFC usage | Users report working curves on PH315/PH317-class units **and** conflict when PredatorSense/EC also writes |
| Various Legion Gen5/6 WinRing0 tools | Full curves via I/O; same risk class as kernel helpers we avoid |

### Platform thermal middleware (context only)

| Item | Notes |
|------|-------|
| Intel **DTT** (Dynamic Tuning) | OEM-configured CPU/GPU power and thermal policies on modern Intel systems; Intel warns against removing it. Limited relevance as a user lever on 2017 7700HQ vs current H-series |
| NVIDIA `nvidia-smi` | Power/temp/clock telemetry and optional power limits — useful for **read-only** “who is limiting” (#9), not a fan substitute |

## GPU side (often under-weighted)

| Approach | Role on PH317-51 |
|----------|------------------|
| Asymmetric CPU vs GPU fan % | After Custom matrix validation (#10, #15) |
| GPU telemetry (`nvidia-smi`) | Confirm thermal vs power limit before more fan |
| Afterburner / GPU undervolt | Optional, outside fail-closed core |
| MUX / Advanced Optimus | Not available like modern ROG; 2017 Optimus is limited |

Reviews of Helios-class machines often show the **CPU path** as the tighter constraint under sustained all-core load; GPU-only fan boost does not fix FMA/AVX package heat.

## What we are *not* missing

- A universal open-source “G-Helper for every Acer 2017” with evidence + fail-closed + native turbo does **not** appear in the public landscape.
- NBFC-on-Helios is a known **alternative path**, not a better safety model for this project’s non-goals (no EC poke, no vulnerable kernel writers).
- ThrottleStop-style MSR control remains intentionally out of scope (CVE class, VBS/HVCI posture).

## Product ideas worth borrowing (stay on WMI)

| Source | Idea | Maps to |
|--------|------|---------|
| G-Helper | Composite profiles: fan policy + Windows power plan (+ optional GPU target); AC vs DC | #14 lifecycle, native turbo pairing |
| G-Helper FAQ | Firmware executes the curve; userspace **sets mode/profile**, does not fight the EC each second | Architecture discipline |
| LLT plugin | Predictive rise (dT/dt), EMA, soft step-down, hard safety = max fans | Future policy beyond binary AUTO/MAX |
| MSI Cooler Boost | Full blast as **overlay** on current profile, not the only lifestyle mode | MAX / CoolBoost (#13) |
| Acer-P-Helper | Thin tray over same WMI | Optional UI after modularization (#17) |
| Multi-vendor | Read GPU limits before assuming fan duty | #9 limit telemetry |

## Explicit non-goals (reinforced)

- NBFC or any permanent dual-writer EC config as the production control plane
- WinRing0 / `ThrottleStop.sys` / similar
- Disabling Intel DTT or thermal/firmware protections as a “performance” step
- Claiming multi-model Acer compatibility without per-SKU evidence

## Relation to other research docs

- [platform-thermal-context.md](platform-thermal-context.md) — **why** this laptop needs intervention (Acer platform primary)
- [forum-sources.md](forum-sources.md) — Helios thermal reports
- This file — **how** the industry controls the same class of problem

## Implementation docs (when promoting ideas)

- [docs/architecture.md](../docs/architecture.md)
- [docs/wmi-surface.md](../docs/wmi-surface.md)
- [docs/roadmap-next-controls.md](../docs/roadmap-next-controls.md)
- [docs/native-turbo-plan.md](../docs/native-turbo-plan.md)
