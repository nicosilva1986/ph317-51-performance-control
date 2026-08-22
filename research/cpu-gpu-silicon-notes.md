# CPU and GPU silicon notes (PH317-51)

**Date:** 2026-08-22  
**CPU:** Intel Core i7-7700HQ (Kaby Lake-H)  
**GPU:** NVIDIA GeForce GTX 1060 Mobile (Pascal, typical non-Max-Q)  
**Status:** Research synthesis. Local package-power figure from evidence; other figures are datasheet/review until re-measured.

## Why this note exists

Fan Auto vs Max and the 28× cap are well covered in the repo. This document captures **silicon and platform power facts** that still shape sustained performance after fans and ratio policy are fixed.

Related: [platform-thermal-context.md](platform-thermal-context.md), [gpu-thermal-and-undervolt.md](gpu-thermal-and-undervolt.md), [prochot-and-tcc-offset.md](prochot-and-tcc-offset.md).

---

## i7-7700HQ

| Parameter | Typical value |
|-----------|---------------|
| Cores / threads | 4 / 8 |
| Base | 2.8 GHz (**28×**) |
| Turbo 1-core | up to **3.8 GHz (38×)** |
| Turbo 2-core | ~**3.6 GHz (36×)** |
| Turbo 3–4 core (all-core) | ~**3.4 GHz (34×)** |
| TDP | **45 W** |
| Configurable TDP-down | **35 W** (OEM/OS may apply) |
| iGPU | HD Graphics 630 (shares package power/thermal) |
| Multiplier | Locked (no all-core OC to 38× via userspace alone) |

### Implications for this project

1. **28× is base, not a mild trim.** Stock all-core turbo is ~34×. Native turbo recovery should log **1C/2C/4C ratios and package watts**, not assume continuous 3.8 GHz under FMA.
2. **PL1 / PL2 / Tau** (package power limits + turbo time window) are OEM-configured. Sustained clocks after removing 28× depend on these and cooling, not marketing max turbo alone.
3. **cTDP-down 35 W** can explain “low package power” without thermal throttle if the platform selected the lower envelope (battery, power plan, EC).
4. Evidence under Max fans reported **~31.7 W package** with the 28× cap (`evidence/benchmarks/2026-08-21-fan-auto-vs-max.json`) — consistent with an artificially limited ratio, far below 45 W TDP headroom.

### C-states / Speed Shift

If C-states are disabled or broken, some units cannot reach the full **38×** 1-core bin. Worth verifying when validating native turbo (read-only), not a fan-stack concern.

---

## GTX 1060 Mobile

| Parameter | Typical value |
|-----------|---------------|
| Architecture | Pascal (GP106), GPU Boost **3.0** |
| CUDA cores | 1280 |
| Memory | Often **6 GB** GDDR5, 192-bit |
| TGP (full mobile) | ~**80 W** |
| Max-Q variant | ~60–70 W, same product name, less performance |
| PH317-51 class | Expect **non-Max-Q ~80 W** unless proven otherwise |
| Display path | **Optimus** (no modern MUX “Ultimate” mode) |

### Implications

1. GPU design power is **almost 2× CPU TDP**. Under 3D load the dGPU can dominate chassis heat even if CPU util looks moderate.
2. **GPU Boost 3.0** tracks power target, temperature target, and V/F curve — undervolt/PL and fan Max both feed this loop differently (generation vs extraction of heat).
3. Current Auto vs Max evidence is **CPU FMA only**; GPU dominance on *this* unit is hypothesis until issue #24 3D runs exist.
4. Operator UV/PL via Afterburner remains **out-of-band** (see [gpu-thermal-and-undervolt.md](gpu-thermal-and-undervolt.md)).

---

## Shared platform constraints

### Heatpipes

CPU and GPU share cooling paths on Helios 300-class designs. GPU watts raise CPU package temperature in games; CPU all-core raises GPU ambient. Fan Max helps both; GPU-only UV helps most when the dGPU is loaded.

### AC adapter ceiling

PH317-51 units ship with **135 W** and **180 W** class adapters depending on SKU/region. Reviews measured system peaks on the order of **~160 W** under load.  
**CPU 45 + GPU 80 + rest** can approach a weak or degraded brick → platform/EDP limits that look like “mystery throttle.” Record adapter wattage in future evidence manifests when known.

### Limit stack (read order for diagnostics)

```text
1. Artificial ratio (28×) — software, local to reference machine
2. PL1 / PL2 / Tau / cTDP — package power policy
3. Tcc offset → early PROCHOT — see prochot-and-tcc-offset.md
4. PROCHOT @ TjMax — Intel thermal safety
5. BD PROCHOT — external pin/EC/GPU/PSU path
6. GPU power / temp targets — NVIDIA Boost
7. Fan policy Auto vs Max — Acer WMI (this project's core)
```

---

## Measurement gaps (reference machine)

- [ ] Sustained clocks and package W **without** 28× (native turbo plan)
- [ ] Explicit read of PL1/PL2 if exposed; cTDP mode if detectable
- [ ] 3D workload: GPU power, temp, clocks, CPU package (issue #24)
- [ ] Adapter label watts noted in evidence metadata
- [ ] PROCHOT trip temperature / Tcc offset / BD PROCHOT flags under Auto and Max

---

## Non-goals

- Unlocking all-core 38× (not supported as stock behavior).
- Flashing GPU VBIOS or changing EC power tables.
- Disabling thermal protections from the fan service.
