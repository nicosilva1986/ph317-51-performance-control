# PROCHOT, BD PROCHOT, and Tcc Activation Offset

**Date:** 2026-08-22  
**Status:** Research. Prefer **read-only** observation on the reference PH317-51. Writing MSRs or disabling protections is outside the fan control plane and requires an explicit safety decision (see `AGENTS.md`).

## Three mechanisms (do not conflate)

| Name | Trigger | Typical effect |
|------|---------|----------------|
| **PROCHOT / TCC** | On-die DTS reaches TCC activation temperature | Adaptive frequency/voltage reduction (Thermal Control Circuit) |
| **Tcc Activation Offset** (aka PROCHOT Offset) | OEM/BIOS programs MSR so TCC trips **below** TjMax | e.g. TjMax 100 °C, offset 15 → throttle from **85 °C** |
| **BD PROCHOT** | External assertion of PROCHOT# (EC, VRM, GPU, battery, charger, failed sensor…) | Often forces **minimum multiplier (~8× / ~800 MHz)** even when CPU die is cool |

Intel’s adaptive thermal monitor is always present as a safety net. It is **not** a substitute for adequate cooling at PL1.

---

## Tcc Activation Offset

### Hardware view

- MSR **`IA32_TEMPERATURE_TARGET` (0x1A2)** holds TjMax / TCC activation temperature and an offset field (bit positions vary slightly by generation).
- Optional **Tau** window: EWMA temperature management in addition to instantaneous TjMax trip.
- **LOCK** bit: BIOS may make the register read-only.

\[
T_{\mathrm{throttle}} \approx T_{\mathrm{jMax}} - \mathrm{Offset}
\]

| Offset | Example trip (TjMax = 100 °C) |
|-------:|------------------------------|
| 0 (Intel default) | 100 °C |
| 5 | 95 °C |
| 10 | 90 °C |
| 15 | 85 °C |

OEMs with tight coolers sometimes raise the offset so turbo dies earlier. Helios community FAQ language around **~90 °C turbo cut** may reflect policy and/or offset — **measure on this unit**.

### Not the same as

- **Fan T-control offset** (related MSR fields on some gens): hint for when fans should engage, not the TCC trip itself.
- **AVX ratio offset** or **voltage undervolt offset**.

---

## PROCHOT (internal)

- When any package DTS hits the (possibly offset) TCC point, **PROCHOT#** is asserted and TCC reduces power.
- Behavior is **graduated**: slow down as needed to stay near the limit.
- Fans that lower die temperature **reduce time in TCC**; they do not change the programmed offset.

---

## BD PROCHOT (bi-directional)

### Mechanism

- PROCHOT# can be driven **into** the CPU from the board when **BD PROCHOT** is enabled (commonly discussed as bit 0 of **`MSR_POWER_CTL` 0x1FC**).
- Intel leaves the external use case to OEMs (VR protection, EC policy, etc.). There is **no public standard** listing which sensor maps to the pin on a given Acer board.

### Symptoms

- Clocks collapse toward **~800 MHz**.
- CPU temperature may be **moderate**.
- Tools show **BD PROCHOT**, not necessarily “PROCHOT 100 °C”.

### Helios-class reports

Community threads on Helios 300 describe BD PROCHOT spikes (e.g. AC/battery transitions, heavy GPU + overlay software). Relevant as family risk, not proof for the reference PH317-51 until logged.

### Community workaround vs project posture

| Action | Community | This repository |
|--------|-----------|-----------------|
| Uncheck BD PROCHOT in ThrottleStop | Common | **Not** automated by fan/watchdog services |
| Claim “thermal still protects the die” | Often true for *internal* PROCHOT | Still forbids routine disable without user safety approval |
| Read flags into evidence JSON | — | **Desired** (telemetry) |

Disabling BD PROCHOT ignores **external** alarms (including legitimate VRM/EC faults). Internal die PROCHOT remains a separate path.

---

## Useful MSRs / observables (read-only)

| Location | Role |
|----------|------|
| `IA32_TEMPERATURE_TARGET` (0x1A2) | TjMax, Tcc offset, Tau, lock |
| `MSR_POWER_CTL` (0x1FC) | BD-PROCHOT enable |
| `IA32_THERM_STATUS` (0x19C) | Per-core thermal status |
| `IA32_PACKAGE_THERM_STATUS` (0x1B1) | Package thermal status |
| `MSR_*_PERF_LIMIT_REASONS` (e.g. 0x690) | Why performance was limited |

Prefer documenting **observed** trip temperature and limit reasons over writing MSRs. ThrottleStop/HWiNFO can help in lab; long-term dependency on `ThrottleStop.sys` remains undesirable (CVE class).

---

## Interaction with project evidence

| Scenario | What fans change | What they do not change |
|----------|------------------|-------------------------|
| Auto FMA peak 91 °C | Max cut peak to 79 °C | Programmed Tcc offset |
| Genuine PROCHOT at high temp | Lower duty cycle in TCC | Need for cooling hardware |
| BD PROCHOT from bad sensor | Nothing reliable | Requires board/EC diagnosis or conscious BD disable |
| 28× ratio cap | Indirect (less heat if slower) | Cap itself |

When validating **native turbo**, log in parallel: package W, core ratios, PROCHOT/BD flags, and implied offset. Otherwise “still slow after Max fans” is ambiguous.

---

## Suggested evidence fields

```text
prochotTripC          // reported thermal trip point if visible
tccOffsetC            // TjMax - trip, if both known
bdProchotSeen         // boolean during run
limitReasons          // PL1, thermal, BD PROCHOT, etc.
```

---

## Non-goals

- Shipping MSR writers in the SYSTEM fan controller.
- Default-disable of BD PROCHOT or Tcc offset “for performance.”
- Treating PROCHOT education as permission to remove thermal safety.

## See also

- [cpu-gpu-silicon-notes.md](cpu-gpu-silicon-notes.md)
- [docs/limit-telemetry-proposal.md](../docs/limit-telemetry-proposal.md)
- Issue #9 (limit telemetry), #2 (native turbo)
