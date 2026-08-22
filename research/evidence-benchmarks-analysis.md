# Analysis of existing thermal-control evidence

**Date:** 2026-08-22  
**Sources:** `evidence/benchmarks/*.json`, `evidence/manifests/fan-release-2026-08-21.json`, `src/powershell/fan/fan-controller-config.json`

This note interprets **what the repo already measured**. It is not a substitute for the raw JSON.

---

## 1. Fan Auto vs Max (sustained CPU load)

File: `2026-08-21-fan-auto-vs-max.json`

| Fixed condition | Value |
|-----------------|-------|
| Workload | NumPy OpenBLAS AVX2/FMA, 6144² float64, 8 threads, 10 min |
| CPU profile | **28× multiplier cap** |
| Max path | `AcerGamingFunction` WMI; **6122 RPM** CPU and GPU fans |

| Metric | Auto | Max | Δ |
|--------|-----:|----:|--:|
| Max temp °C | 91.0 | 79.0 | **−12.0** |
| Average °C | 86.8 | 76.3 | **−10.5** |
| p95 °C | 90 | 79 | **−11** |
| Iterations / 10 min | 153 | 166 | **+8.5%** |
| Mean s/iter | 3.935 | 3.635 | **−7.6%** |
| WHEA | 0 | 0 | — |
| Package power max W | — | **31.7** | Max only |

### Interpretation

1. **Firmware Auto is late/weak under sustained FMA** relative to Max on this unit and paste/dust state.
2. Throughput rose **with the same ratio cap** → thermal (or related) limiting still hurt Auto; cooler headroom is not only “comfort.”
3. **31.7 W package under Max** shows the experiment is **not** a full 45 W TDP stress; 28× dominates the power envelope. Re-run after native turbo before claiming Max vs Auto deltas at stock turbo bins.
4. Peak Auto **91 °C** sits in the Helios FAQ “turbo trouble” band (~90–96 °C community guidance). Max at 79 °C stays clear of that band for this workload.

### Gaps

- No time series (when Auto spins up).
- No adaptive-controller arm vs fixed Max.
- No GPU/3D arm.
- Package power not logged on Auto.
- Ambient / paste age not in JSON.

---

## 2. Control-plane recovery (not thermal A/B)

### Override recovery — `2026-08-21-override-recovery.json`

- Forced firmware Auto while controller desired Max.
- Recovered to Max-class behavior in **~4.2 s** (`PASS`).
- `fanBehavior` 512 → 256 → 512 (consistent with documented mode encoding).
- Final RPM **5084** (≥ config `minimumMaxRpm` 5000), not necessarily peak 6122 at sample time.

### Watchdog recovery — `2026-08-21-watchdog-recovery.json`

- Primary controller task stopped; watchdog remained.
- Restart + **MAX / HEALTHY_VERIFIED** / 6122 RPM in **~8.0 s** (`PASS`).

### Install manifest — `fan-release-2026-08-21.json`

- Hash-pinned install, tasks running, Max readback verified. Integrity baseline, not a stress test.

**Interpretation:** Fail-closed and single-writer recovery are **demonstrated** for these scenarios. Open issues on debounce/spin-up (#18, etc.) can still refine edge cases without voiding these PASSes.

---

## 3. Controller config vs measured Auto temps

From `fan-controller-config.json` (selected):

| Key | Value | vs Auto FMA (~87 °C avg) |
|-----|------:|---------------------------|
| `maxCpuC` / preempt temps | 60 / 55 | Adaptive would request Max early |
| `criticalCpuC` | 75 | Auto peak 91 exceeds |
| `releaseCpuC` + long release samples | 55 + conservative timers | Slow leave from Max (fail-closed bias) |
| `minimumMaxRpm` | 5000 | Met in recovery and Max steady |
| `riseTriggerC` | 4 °C / 6 s window | Aligns with predictive policy ideas |

Under this FMA profile, binary Max vs the adaptive controller would likely **agree** on spending most of the run in Max.

---

## 4. What these benchmarks justify

| Claim | Supported? |
|-------|------------|
| WMI Max improves thermals vs Auto under this FMA + 28× | **Yes** |
| That improvement can raise throughput under same ratio cap | **Yes** |
| Stack can re-assert Max after override / controller death | **Yes** |
| Ready to drop 28× without new evidence | **No** |
| GPU is the main heat source on this unit | **Not measured** |
| Custom % beats binary Max | **Not measured** |

---

## 5. Next evidence priorities (ordered)

1. Same FMA protocol **without** 28× — Auto / Max / adaptive; log ratios, package W, limit reasons, PROCHOT/BD flags.
2. Time-series samples (temp, RPM, mode).
3. 3D workload + `nvidia-smi` (issue #24).
4. Optional: adapter wattage in manifest metadata.

See also [cpu-gpu-silicon-notes.md](cpu-gpu-silicon-notes.md), [prochot-and-tcc-offset.md](prochot-and-tcc-offset.md).
