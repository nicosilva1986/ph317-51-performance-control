# Native Turbo / Speed Shift plan

## Finding

The local ThrottleStop profile set `Payload1..4=0x1C00`, imposing 28x in every profile. The stored stock table `0x22232426` corresponds to Intel ratios:

| Active physical cores | Stock maximum |
|---:|---:|
| 1 | 38x / 3.8 GHz |
| 2 | 36x / 3.6 GHz |
| 3 | 35x / 3.5 GHz |
| 4 | 34x / 3.4 GHz |

The 7700HQ is multiplier-locked. This project can remove the artificial 28x cap; it cannot produce legitimate 38x all-core operation.

## Why native control

Windows and Intel Hardware P-states already select frequency according to active cores, load, temperature, current and package power. An aggressive EPP can request performance without a userspace daemon constantly rewriting multipliers.

## Controlled migration

The reference machine's existing power-plan catalog is malformed: even Balanced lacks `SUB_PROCESSOR`. Migration must be an explicit, measured transaction:

1. Export the ThrottleStop task XML, INI/hash, power-plan list and the PowerSchemes registry branch.
2. Rebuild Windows default plans with `powercfg /restoredefaultschemes` and verify `SCHEME_BALANCED SUB_PROCESSOR` exists.
3. Duplicate fresh Balanced as `Predator Native Turbo`.
4. Set AC processor minimum 5 %, maximum 100 %, boost mode Aggressive, boost policy 100 %, autonomous mode enabled, EPP 0, active cooling, and stock Intel limits.
5. Preserve the user's explicit behavior: no automatic sleep/hibernate, lid close does nothing, no password-on-wake. Keep DC conservative until AC validation passes.
6. Activate and query every value.
7. Disable ThrottleStop auto-start, stop its process/driver, and verify the vulnerable driver is unloaded. Preserve configuration only as local rollback evidence.
8. Validate 1-, 2-, 3- and 4-core behavior, then the identical ten-minute FMA workload, followed by combined CPU+GTX 1060 load.

## Acceptance criteria

- expected stock ratio envelope, never a claimed all-core 38x;
- zero computational errors and zero new WHEA events;
- CPU temperature p95 ≤85 °C under the selected workload;
- automatic abort at ≥92 °C;
- no persistent `THERMAL` or `BD PROCHOT` limit;
- VBS/HVCI remains enabled;
- phase 1 does not touch undervolt, PL1/PL2/PL4, IccMax or BD PROCHOT.

Only after the stock-native baseline passes may a separately reviewed experiment change a power limit, one step at a time.
