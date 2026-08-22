# GPU thermal role and undervolt landscape (GTX 1060 laptop)

**Date:** 2026-08-22  
**Platform:** Acer Predator PH317-51 / NVIDIA GeForce GTX 1060 (mobile Pascal)  
**Status:** Research only. Not part of the privileged fan/turbo control plane.

## Question

Does a ThrottleStop-like undervolt path exist for the GPU, and what would we
actually improve by using it on this chassis?

## Short answers

1. **Yes**, GPU undervolt / power limiting exists. The usual tool is **MSI Afterburner** (voltage/frequency curve editor), not ThrottleStop.
2. The real goal is **same (or more stable) graphics performance at lower power and heat**, not “more FPS for free.”
3. On PH317-51, CPU and GPU **share heatpipes**, so GPU heat can raise CPU package temperature under gaming load.
4. Current repo evidence (`evidence/benchmarks/2026-08-21-fan-auto-vs-max.json`) is **CPU FMA with a 28× cap** — it does **not** quantify GPU contribution under 3D load.

## CPU vs GPU control mechanisms

| | CPU (ThrottleStop / XTU) | GPU (mobile GTX 1060) |
|--|--------------------------|------------------------|
| Mechanism | MSR / Intel interfaces | NVIDIA GPU Boost V/F table + power limit |
| Typical tool | ThrottleStop, Intel XTU | **MSI Afterburner** (Ctrl+F curve), optional power slider |
| This project | Avoided in phase 1 (CVE-class drivers, VBS posture, native turbo plan) | Optional **userspace** tune; not SYSTEM fan writer |

There is no official “ThrottleStop for GPU.” Afterburner is the de facto community path for Pascal/Turing/Ampere mobile undervolt.

## What undervolt / power limit improves

| Outcome | When it happens |
|---------|-----------------|
| Lower GPU temperature | Almost always if voltage/power actually drops |
| Same FPS, less heat | Successful UV at near-stock clocks |
| More **sustained** FPS | Only if stock was hitting thermal or power limit and clocks were falling mid-session |
| Lower CPU temperature in games | Common on shared-heatpipe chassis when GPU watts fall |
| Less fan noise / less time at Max | If total system heat drops |
| Lower wall power | Direct consequence of fewer GPU watts |

### What it does *not* replace

- Firmware **Auto** fan lag (still an Acer policy problem).
- WMI Max / adaptive controller (extraction of heat).
- Removing the artificial **28×** CPU multiplier cap (CPU throughput).
- A guarantee of higher peak FPS; peak can stay flat or drop slightly if the curve is too aggressive.

**One line:** undervolt reduces **heat generation**; fans improve **heat extraction**. Complementary, not substitutes.

## Community / industry notes (not local evidence)

- Mobile **Pascal** (1060/1070/1080) is widely reported as responsive to V/F undervolt via Afterburner.
- Helios 300 + GTX 1060 guides exist in the wild (Afterburner curve profiles).
- Typical community reports: several–~10 °C GPU drop when locking a lower mV point at similar MHz; sometimes CPU also cooler under gaming because of shared cooling.
- **Power limit** slider alone is a coarser, easier first step; full curve is more efficient per watt when tuned per silicon.
- Some OEM BIOSes lock or narrow the curve; PH317-class 1060 units often allow edits, but **this reference machine is untested** in-repo.

Treat all °C/FPS claims above as **hypothesis until measured** on the reference PH317-51.

## Shared thermal path (platform fact)

From [platform-thermal-context.md](platform-thermal-context.md) and Helios-era reviews: dual fans with **shared CPU/GPU heatpipes**. Implications:

- Gaming load: GPU can be a major heat source even if CPU util looks moderate.
- FMA/AVX all-core: CPU dominates (matches current Auto vs Max benchmark design).
- Fan Max helps **both** dies; GPU-only UV helps most when the dGPU is loaded.

## Relation to existing evidence

| Artifact | GPU role |
|----------|----------|
| `2026-08-21-fan-auto-vs-max.json` | CPU-bound; 28× fixed; GPU not the subject |
| Override / watchdog recovery JSON | Fan control plane only |
| Issue #9 limit telemetry | Natural place for **read-only** `nvidia-smi` (temp, power, clocks, throttle reasons) |

## Project posture (non-goals and allowed work)

### In scope for the repository (when prioritized)

1. **Read-only GPU telemetry** during workloads (extends #9).
2. **Evidence protocol**: fixed game or synthetic 3D load, fans Auto vs Max vs adaptive, log CPU/GPU temp, GPU power, clocks, fan RPM, WHEA.
3. Document optional **operator** Afterburner use as *out-of-band* (README/research), not as a service dependency.

### Out of scope for the privileged stack

- Shipping or requiring MSI Afterburner / curve profiles inside the SYSTEM controller.
- Treating GPU undervolt as a substitute for fail-closed Max recovery.
- Claiming multi-SKU undervolt recipes without per-unit stability tests.

## Suggested measurement order (reference machine)

```text
1. Baseline game/synth 15–20 min, stock GPU, fans Auto  → telemetry JSON
2. Same load, fans Max (WMI)                              → compare temps/FPS
3. Same load, adaptive controller                         → duty cycle in Max
4. Only if GPU is power/thermal limited: Afterburner PL or UV (userspace)
5. Re-run (2) or (3) with UV to quantify shared-heatpipe CPU relief
```

Do not start at step 4 without steps 1–2; otherwise “GPU is a massive heat raiser” stays anecdotal relative to this unit’s paste/dust/BIOS state.

## Links to promote later

- Implementation: `docs/limit-telemetry-proposal.md`, issue tracker GPU issue.
- Fans: `docs/wmi-surface.md`, `docs/architecture.md`.
- Platform: `platform-thermal-context.md`, `cross-vendor-control-landscape.md`.
