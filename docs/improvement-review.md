# Improvement review — 2026-08-22

Independent read of the whole tree (13.5k lines) against the repository's own
rules in [`AGENTS.md`](../AGENTS.md), against mainline `acer-wmi`, and against
comparable public projects.

Findings are ranked by the cost of leaving them alone. Every claim below cites
the exact file and line it came from; nothing here was inferred from a
description or a commit message.

## Relationship to the roadmap

[`roadmap-next-controls.md`](roadmap-next-controls.md) landed independently and
covers the *forward* work: limit telemetry (A), the Custom % matrix (B), binary
policy tuning (C), CoolBoost (D), resume/AC–DC (E), GPU-first policy (F). Two
findings here were reached independently and are already tracked there — **S4**
is workstream E, and **S7** is workstream B, whose candidate word `0x00C30009`
this review independently confirms against mainline (`SET_CPU_MODE_MASK`
`GENMASK(17, 16)` with value 3 = `0x00030000`; `SET_GPU_MODE_MASK`
`GENMASK(23, 22)` with value 3 = `0x00C00000`). Those two sections are kept for
the supporting evidence, not as competing proposals.

The remaining eight findings are **not** on the roadmap, and three of them are
defects in code that is already in the hot path. That is the gap this document
is for: the roadmap plans new capability on top of a controller that has an
untested restart loop (S1), a decode inconsistency (S2), and no way to
regression-test either (S3).

One dependency worth making explicit: workstream B's own implementation sketch
requires "extend simulation tests with Custom transitions before live install".
That is **not possible today** — the simulation harness cannot reach any
readback or mode-transition path (see S3). **S3 is a prerequisite for
workstream B**, not a parallel cleanup.

## What the review confirmed as correct

Worth stating first, because it constrains the rest of the recommendations.

- **The WMI surface map is accurate.** Every encoding in
  [`docs/wmi-surface.md`](wmi-surface.md) matches mainline
  `drivers/platform/x86/acer-wmi.c`:
  `ACER_GAMING_FAN_BEHAVIOR_SET_CPU_MODE_MASK GENMASK(17, 16)`,
  `SET_GPU_MODE_MASK GENMASK(23, 22)`, `GET_CPU_MODE_MASK GENMASK(9, 8)`,
  `GET_GPU_MODE_MASK GENMASK(15, 14)`, and
  `ACER_WMID_FAN_MODE_AUTO = 0x01 / _TURBO = 0x02 / _CUSTOM = 0x03`.
  The controller's `0x00820009` decodes to CPU mode 2 + GPU mode 2, and
  `0x00410009` to CPU mode 1 + GPU mode 1. Both are right.
- **The CRUW bootstrap trust chain is sound.** `Assert-CRUWSealedBootstrap`
  hashes `CRUWStateMachine.Common.ps1` *before* dot-sourcing it
  (`Invoke-CRUWBlockerRemoval.ps1:409-437`), so the seal verifier is not itself
  loaded from the unverified file. This is the failure mode most projects get
  wrong; this one does not.
- **CI supply-chain hygiene is above average.** `actions/checkout` is pinned by
  commit SHA, `persist-credentials: false`, and `permissions: contents: read`.
- **Evidence sanitization holds.** No device instance IDs, serials, usernames or
  machine names anywhere in `evidence/`.

The findings below are therefore about gaps, not about a weak foundation.

---

## S1 — Watchdog restarts a healthy controller during normal fan spin-up

**Severity: high. This is the one to fix first.**

The controller publishes `REASSERT_PENDING` whenever it is in `MAX` but the fans
have not yet reached `minimumMaxRpm`:

```powershell
# AcerAdaptiveFanController.ps1:412-415
elseif ($state -eq 'MAX') {
    $mode = ...
    if ($mode -eq 2 -and [int]$sample.cpuFanRpm -ge [int]$script:Config.minimumMaxRpm -and
        [int]$sample.gpuFanRpm -ge [int]$script:Config.minimumMaxRpm) { 'HEALTHY_VERIFIED' } else { 'REASSERT_PENDING' }
}
```

The controller itself treats that as expected and gives the hardware
`verifyMaxAfterSeconds: 12` to get there. The watchdog does not:

```powershell
# AcerFanWatchdog.ps1:110
if ([string]$status.status -ne 'HEALTHY_VERIFIED') { throw "Primary health code is $([string]$status.status)." }

# AcerFanWatchdog.ps1:223-226 — a single observation is enough
if (-not $taskHealthy -or -not $health.valid) {
    Invoke-EmergencyRecovery -Reason "..."
}
```

`Invoke-EmergencyRecovery` forces `MAX` (correct, fail-closed) and then **stops
and restarts the primary scheduled task** (`AcerFanWatchdog.ps1:174-180`).

### Consequence

`minimumMaxRpm` is 5000 and measured `MAX` is 6122 RPM. A cool-idle fan sits far
below 5000. On every `AUTO -> MAX` transition the fans need several seconds of
spin-up, during which the controller correctly reports `REASSERT_PENDING`. The
watchdog polls every 10 seconds, so it will frequently sample that window and
kill the controller mid-transition.

Restarting the controller is not free: it discards `maxSince`, `coolSamples`,
`loadSamples` and the entire `temperatureHistory` queue, and re-enters `MAX`
from scratch. Hysteresis — principle 4 in [`architecture.md`](architecture.md) —
is silently reset by the component whose job is to protect it.

### Why this is an internal inconsistency, not a judgement call

The installer already solved exactly this problem and requires **two consecutive**
healthy samples before declaring success:

```powershell
# Secure-Install-AcerFanController.ps1:344-346
$consecutiveHealthy++
if ($consecutiveHealthy -ge 2) { break }
```

The watchdog is the only health consumer without that debounce.

### Recommended fix

Keep the immediate `Set-EmergencyMax` — that must stay instantaneous and
fail-closed. Debounce only the **restart**:

- treat `REASSERT_PENDING` as *degraded but progressing*, distinct from
  `DEGRADED_FAIL_SAFE`, missing, stale, or malformed;
- require N consecutive unhealthy observations (N=2, or a grace window derived
  from `verifyMaxAfterSeconds`) before stopping the primary task;
- reset the counter on the first `HEALTHY_VERIFIED`.

Stale/missing/malformed heartbeat and an altered task definition should keep
restarting on the first observation — those are not transients.

### Test gap that hid it

`tests/Test-AcerFanWatchdog.ps1` covers `DEGRADED_FAIL_SAFE`, malformed, missing,
future-dated and hash-mismatch. It never writes a `REASSERT_PENDING` heartbeat.
Add that case plus a "transient pending then healthy must not trigger restart"
case.

---

## S2 — `REASSERT_PENDING` detection in `MAX` uses an exact-value compare

**Severity: medium (latent), but it is a one-line fix.**

Every other mode decode in the tree uses the documented bitfield mask. One does
not:

```powershell
# AcerAdaptiveFanController.ps1:379
$profileMismatch = ($null -ne $behaviorValue -and [uint32]$behaviorValue -ne [uint32]512) -or ...
```

Compare with `:338`, `:413`, `:417`, `AcerFanWatchdog.ps1:114` and
`Secure-Install-AcerFanController.ps1:336`, which all use
`([uint32]$raw -shr 8) -band 3`.

Mainline `acer-wmi` puts GPU mode in `GET_GPU_MODE_MASK GENMASK(15, 14)` of the
same word. The reference PH317-51 firmware happens to report that field as `0`,
which is why `512` works today and is honestly documented as an *observed*
compact return in [`wmi-surface.md`](wmi-surface.md). But if a BIOS update or a
different unit ever populates the GPU field, a perfectly healthy dual-turbo
readback becomes `0x0200 | (2 << 14)` = `33280`. Then:

- line 379 flags a mismatch and reasserts `MAX` every
  `rpmReassertMinIntervalSeconds` (10 s) **forever**, while
- line 413 decodes CPU mode 2 correctly and keeps publishing
  `HEALTHY_VERIFIED`.

An endless reassert loop with a green status is a bad failure mode for a
component whose whole contract is "observed state beats requested state".

### Recommended fix

Decode both documented fields and enforce them independently, treating a `0` GPU
field as "not reported by this firmware" rather than as a mismatch:

```powershell
$cpuMode = ([uint32]$behaviorValue -shr 8) -band 3
$gpuMode = ([uint32]$behaviorValue -shr 14) -band 3
$modeMismatch = $cpuMode -ne 2 -or ($gpuMode -ne 0 -and $gpuMode -ne 2)
```

The same decode belongs in the `AUTO` branch (`:338`), which today checks CPU
mode only and never looks at the GPU field at all.

### Documentation follow-up

`wmi-surface.md` lists the sensor words as opaque constants (`0x0101`, `0x0A01`,
`0x0301`, `0x0201`, `0x0601`). Mainline models them as
`ACER_WMID_CMD_GET_PREDATOR_V4_SENSOR_READING` (`0x01`, low byte) plus a sensor
index in the high byte. Documenting that decomposition — index `0x01` CPU temp,
`0x0A` GPU temp, `0x03` system temp, `0x02` CPU fan, `0x06` GPU fan — makes the
table self-explaining and matches upstream naming.

---

## S3 — The simulation harness cannot reach the safety-critical code

**Severity: high for maintenance, even though nothing is broken right now.**

Three of the controller's most important behaviours are gated behind
`-not $simulation`:

| Line | Behaviour | Reachable in CI? |
|---:|---|---|
| 336 | external override correction in `AUTO` | no |
| 365 | `max_verification_retry` / `max_verified` | no |
| 377 | override correction + RPM mismatch in `MAX` | no |

So `Test-AcerAdaptiveFanController.ps1` — six simulation cases, all green —
verifies the thermal *policy* but **cannot** verify readback, reassertion, or
mismatch handling. Those paths are exercised only by
`Test-AcerFanOverrideRecovery.ps1`, which requires the physical laptop and never
runs in CI. S2 above is exactly the kind of bug that survives in that blind spot.

### Recommended fix

The repository already contains the right pattern in the other subsystem:

```powershell
# CRUWStateMachine.Common.ps1:484
function Invoke-CRUWAdapter {
    param([Parameter(Mandatory)] [hashtable] $Adapter, [Parameter(Mandatory)] [string] $Name, [object[]] $ArgumentList = @())
    if (-not $Adapter.ContainsKey($Name) -or $Adapter[$Name] -isnot [scriptblock]) { throw "Adapter operation missing: $Name" }
    return & $Adapter[$Name] @ArgumentList
}
```

`New-CRUWNativeAdapter` supplies the real implementation; `-TestMode` supplies a
scripted one. This is why the CRUW state machine has 485 lines of simulation
coverage across two PowerShell engines while the fan controller has none for the
same class of logic.

Give the fan controller the same treatment: a `$FanAdapter` hashtable with
`ReadSample`, `SetBehavior`, `SetSpeed`, `GetNow`, injected as native by default
and scripted under simulation. Then delete the three `-not $simulation` guards
and let simulation samples carry `fanBehaviorBitmap` / `cpuFanRpm` / `gpuFanRpm`
so the readback paths execute for real.

Note the CI already enforces this discipline for CRUW — the "Reject unsafe CRUW
removal primitives" step statically proves the entrypoints never bypass the
sealed adapter. The fan side has no equivalent invariant because it has no
adapter.

---

## S4 — No re-assertion on resume from sleep

**Severity: medium. Tracked as roadmap workstream E — this section is the
supporting evidence for it, including a second failure mode E does not mention.**

[`architecture.md`](architecture.md) draws the component diagram as
`Windows startup/resume`, but both task registrations use a startup trigger only:

```powershell
# Secure-Install-AcerFanController.ps1:311  and  AcerFanWatchdog.ps1:161
$trigger = New-ScheduledTaskTrigger -AtStartup
```

There is no resume trigger anywhere in the tree. Two separate problems follow.

**Firmware state after resume is unverified.** The project has never published
evidence of what `GetGamingFanBehavior` returns after S3/S4 on this machine. If
the EC restores its own default curve on resume, the controller only notices via
the mismatch path — which needs `rpmMismatchSamples: 2` plus
`rpmReassertMinIntervalSeconds: 10`, so up to ~14 s of unmanaged fans, and in
the `AUTO` branch it corrects *toward* `AUTO` (see S5). Linuwu-Sense persists
profiles across *reboot* but documents nothing about suspend, so this cannot be
answered from prior art — it needs a measurement on the reference laptop.

**Monotonic and wall clocks diverge and are never reconciled.** The controller
keeps both:

```powershell
# AcerAdaptiveFanController.ps1:238
$monotonic = [Diagnostics.Stopwatch]::StartNew()
```

`$elapsedSeconds` (monotonic) drives `heldSeconds`, `lastMaxWriteSeconds` and the
`temperatureWindowSeconds` pruning; `Get-Date` drives `updatedAt`. Across a
suspend these two disagree. Because the temperature history is pruned on
`elapsedSeconds`, a pre-suspend sample can still be inside the "last 6 seconds"
window after resume, so `$cpuRise` compares a post-resume reading against a
pre-suspend one. That fails *toward* cooling — a spurious `MAX`, not a missed
one — but it is a spurious 5-minute `MAX` (`minMaxSeconds: 300`) on every
resume, attributed to `rapid_temperature_rise`.

### Recommended fix

1. Measure `GetGamingFanBehavior` and both RPMs immediately after resume, and
   record it in `evidence/` — this is a prerequisite, not an optional extra.
2. Add an event trigger on `Kernel-Power` 107 (fires on every resume;
   `Power-Troubleshooter` 1 is documented as unreliable) so the guardians
   re-assert deterministically.
3. Detect divergence between `Get-Date` delta and `$monotonic` delta each poll;
   when it exceeds a threshold, flush `temperatureHistory`, force a
   re-verification of firmware mode, and log a `resume_detected` event.

---

## S5 — External override correction pulls the machine toward *less* cooling

**Severity: medium — a design question, not a defect.**

In the `AUTO` branch the controller corrects any firmware mode that is not `1`
back to `AUTO`:

```powershell
# AcerAdaptiveFanController.ps1:338-343
$cpuFanMode = if ($null -ne $behaviorValue) { ([uint32]$behaviorValue -shr 8) -band 3 } else { $null }
if ($null -ne $cpuFanMode -and $cpuFanMode -ne 1) { $rpmMismatchSamples++ } else { $rpmMismatchSamples = 0 }
if ($rpmMismatchSamples -ge ... ) {
    Set-HardwareFanProfile -Profile 'AUTO'
```

Mode `2` is `TURBO`. So if the owner presses the Acer turbo-fan key, or
PredatorSense sets `MAX`, the controller drags the machine back down to `AUTO`
within roughly 4–14 seconds.

This follows "one writer per control plane" (principle 1) but it is the single
place where the design overrides a human toward less cooling, which sits
awkwardly beside "fail closed toward cooling" (principle 2). It is also the most
likely source of a future "the turbo key does nothing" bug report.

Not necessarily wrong — but it should be a *stated, documented* precedence rule
in `architecture.md` rather than an implicit consequence of the mismatch loop.
An `-AllowExternalMaxOverride` flag, or an explicit "external `TURBO` is honored
for N seconds then reclaimed", would make the intent legible.

---

## S6 — CI reports parse failures without the filename

**Severity: low. Zero-risk fix, applied in this change.**

```yaml
# .github/workflows/ci.yml:30 and :44
$failed += "${($_.FullName)}: $(@($errors).Message -join '; ')"
```

`${...}` is PowerShell's *variable-name* escape, so `${($_.FullName)}` resolves a
variable literally named `($_.FullName)`, which does not exist. Verified
empirically on pwsh 7.4.6:

```
CI-STYLE MESSAGE >>> : SIMULATED-ERROR
CORRECT WOULD BE   >>> .../AcerAdaptiveFanController.ps1
```

Both parse steps — pwsh and Windows PowerShell 5.1 — would therefore fail with
no indication of *which* file failed. Correct form is `$($_.FullName)`.

---

## S7 — Fan policy is binary when the firmware exposes three modes

**Severity: medium. Tracked as roadmap workstream B
([`fan-curve-experiment.md`](fan-curve-experiment.md)), which already specifies
the matrix protocol and pass/fail criteria. This section records the independent
motivation and the upstream cross-check; it does not propose a second design.**

Current thresholds (`fan-controller-config.json`):

| Setting | Value | Effect |
|---|---:|---|
| `pollSeconds` | 2 | |
| `preemptCpuLoadPct` | 30 | |
| `preemptLoadSamples` | 2 | **`MAX` after 4 s above 30 % CPU** |
| `minMaxSeconds` | 300 | **minimum 5 min at 6122 RPM** |
| `releaseSamples` | 150 | then 5 more min of sustained cool |

So opening a browser, running a build, or any 4-second load spike pins both fans
at 6122 RPM for at least five minutes. That is a defensible "performance-first
candidate" for a benchmark, but it is a harsh always-on default: Acer community
threads consistently report fan bearing degradation as a real failure mode on
these chassis, and this policy maximises time at maximum RPM.

The firmware already supports a middle tier. `ACER_WMID_FAN_MODE_CUSTOM = 0x03`
plus `SetGamingFanSpeed` percent is the same surface this repo has already
mapped, and Linuwu-Sense exercises it in production: its `fan_speed` attribute
accepts `0` for auto and `2–100` as a per-fan percentage (`echo 50,70`), so a
CPU/GPU split at an intermediate duty cycle is known-good on this WMI family.

[`architecture.md`](architecture.md) lists "arbitrary custom percent curves on
every poll" as a non-goal, and that reasoning holds — a per-poll curve daemon is
a different risk class. But a **three-state policy** is not a curve daemon:

```
AUTO  ->  CUSTOM (fixed ~70 %, single write on entry)  ->  MAX (100 %)
```

Each state is still a single write on transition, still readback-verified, still
fail-closed to `MAX`. It would cut time-at-6122-RPM substantially while keeping
every existing invariant. `Test-AcerFanOverrideRecovery.ps1` already probes
`GetGamingFanBehavior` across several bitmaps, so the measurement rig exists.

Prerequisite before implementing: confirm on hardware that mode `3` performs a
live percent write on this firmware rather than replaying the last
PredatorSense-saved curve — `wmi-surface.md` already flags that ambiguity for
tray apps and it must be resolved with a readback, not an assumption.
[`fan-curve-experiment.md`](fan-curve-experiment.md) is that measurement, and
its "firmware ignores Custom and stays Auto" fail criterion is exactly the
ambiguity to resolve. Two things this review adds to it:

- its candidate word `0x00C30009` checks out against mainline — worth recording
  in the experiment doc that the encoding was verified against
  `acer-wmi.c`, not only derived from `wmi-surface.md`;
- its implementation sketch calls for simulation coverage of Custom transitions,
  which S3 must land first to make possible.

---

## S8 — Repository is unlicensed

**Severity: medium, and it is a decision only the owner can make.**

There is no `LICENSE` / `COPYING` file. Under default copyright that means
nobody may use, copy, modify, or contribute — and `CONTRIBUTING.md` actively
solicits pull requests, which have no licence to be contributed under.

The README states publication will be a separate decision. That decision needs a
licence choice attached to it. For privileged firmware tooling, the practical
question is whether an explicit warranty disclaimer matters more than
copyleft — MIT/Apache-2.0 (Apache-2.0 adds a patent grant and an explicit
"AS IS" disclaimer) versus GPL-3.0 if derivative firmware tooling should stay
open. I have deliberately not picked one.

While the repo stays private, adding `LICENSE` costs nothing and removes the
ambiguity before the first outside contributor appears.

---

## S9 — Static analysis and CI coverage gaps

**Severity: low individually, meaningful together.**

- **No PSScriptAnalyzer.** CI parses every `.ps1` but never lints one. Current
  practice is a committed `PSScriptAnalyzerSettings.psd1` so every engineer and
  CI share one baseline, with `Error` severity gated first. Known hits in this
  tree: `PSUseApprovedVerbs` (`Rotate-ControllerLog`,
  `Quarantine-CRUWUnilateralJournalTail`, `Apply-Max`) and
  `PSAvoidAssignmentToAutomaticVariable` (`$matches` at `ci.yml:202`, which
  shadows the `-match` automatic variable).
- **`Set-StrictMode` is not universal.** `CRUWBlockerPreflight.Core.ps1` (999
  lines) sets neither `Set-StrictMode` nor `$ErrorActionPreference`;
  `CRUWStateMachine.Common.ps1` (2540 lines) sets strict mode but not
  `$ErrorActionPreference`. Both currently inherit from their dot-sourcing
  callers, which works but is load-order-dependent.
- **CI push filter is narrow.** `branches: [main, "feat/**"]` means `fix/**`,
  `docs/**`, `chore/**` and this branch get no push run. Pull requests still
  run, so this is a latency issue, not a correctness one. A `concurrency` group
  would also stop redundant duplicate runs on the same ref.
- **The secret scan excludes by bare filename.** `ci.yml:199` excludes
  `Test-ExportSanitizedBaseline.ps1` with `-notin`, matching *any* file with
  that name anywhere in the tree, and silently stopping if the file is renamed.
  Prefer a repo-relative path comparison.
- **No dependency/code scanning.** No Dependabot for the pinned action SHAs, no
  CodeQL. Dependabot on `github-actions` would keep the SHA pins current without
  giving up pinning.

## S10 — `CRUWStateMachine.Common.ps1` should be a module

**Severity: low. Purely maintainability.**

70 functions and 2540 lines in one dot-sourced script, loaded whole by 10
separate consumers, with every function landing in the caller's scope and no
declared public surface.

Converting it to a `.psm1` with an explicit `Export-ModuleMember` (or splitting
by topic: journal, storage, integrity, adapters) would give it a real API
boundary. The constraint to respect: `Test-CRUWImplementationSeal` pins the file
*by name and by SHA-256* in the six-artifact contract, so any split is a
schema-v4 change to the sealed bundle, not a refactor. That makes it a
deliberate, planned migration rather than opportunistic cleanup — which is
probably why it has not happened yet, and is a legitimate reason to defer it.

---

## Evidence and documentation accuracy

Two claims deserve tightening.

**The headline benchmark is bound to the 28x cap.** `README.md` presents the
12 °C / 8.5 % result immediately above the design section, and
`evidence/benchmarks/2026-08-21-fan-auto-vs-max.json` correctly records
`"fixedCpuProfile": "28x multiplier cap"`. But
[`native-turbo-plan.md`](native-turbo-plan.md) exists to *remove* that cap, at
which point the 76.3 °C average no longer describes the shipped configuration.
The README should state that the comparison is fan-only at a fixed multiplier
and will need re-measurement after the Turbo migration.

**The Turbo acceptance criteria may be self-conflicting.** The plan asks for
`EPP 0` and boost mode Aggressive (`native-turbo-plan.md:27`) while requiring
`CPU p95 <= 85 °C` (`:37`). The measured p95 at `MAX` fans was 79 °C *with* the
28x cap; unlocking to the stock 34–38x envelope raises package power well above
the recorded 31.7 W. Worth stating explicitly that EPP will likely need to be
tuned upward from 0 to satisfy the thermal criterion, so a failed run reads as
"tune EPP" rather than "the plan failed".

---

## Suggested order of work

This is a *defect* queue and runs alongside the roadmap's capability queue, not
instead of it. Where the two touch, the dependency is noted.

| # | Item | Effort | Risk | Pinned hashes | Roadmap link |
|---|---|---|---|---|---|
| 1 | S6 CI filename interpolation | trivial | none | no | — |
| 2 | S8 LICENSE | trivial | none | no | — |
| 3 | S5 document external-override precedence | trivial | none | no | — |
| 4 | S3 fan adapter injection + simulation coverage | medium | medium | **yes** (controller) | **blocks B** |
| 5 | S1 watchdog restart debounce + test | small | low | **yes** (watchdog) | — |
| 6 | S2 masked GPU/CPU mode decode | small | low | **yes** (controller) | — |
| 7 | S9 PSScriptAnalyzer + strict-mode sweep + CI polish | small | none | no | — |
| 8 | S4 resume measurement, then resume trigger | medium | medium | **yes** | = E |
| 9 | S7 graduated fan policy | large | medium | **yes** | = B |
| 10 | S10 module extraction (schema v4) | large | high | **yes** (sealed bundle) | — |

S3 is deliberately ahead of S1 and S2 here even though it is the larger job: it
is what lets those two fixes be covered by a deterministic cross-engine test
instead of only by a hardware run, and the roadmap's workstream B needs it too.

Items 4, 5, 6, 8 and 9 change privileged control logic. Per `AGENTS.md` each
needs isolated simulations for every affected trigger and failure path, and each
requires re-pinning the SHA-256 values in `Deploy-SecureAcerFanUpdate.ps1:12-17`.

## Sources

- Mainline `acer-wmi` fan behaviour masks, mode enum and method IDs 14/15 —
  <https://raw.githubusercontent.com/torvalds/linux/master/drivers/platform/x86/acer-wmi.c>
- Armin Wolf, "acer-wmi: Add fan control support" (v2, 2025-09) —
  <https://patchew.org/linux/20250923215205.326367-1-W._5FArmin@gmx.de/20250923215205.326367-3-W._5FArmin@gmx.de/>
- Linuwu-Sense `fan_speed` semantics (0 = auto, 2–100 = percent, `cpu,gpu`) —
  <https://github.com/0x7375646F/Linuwu-Sense>
- Fan Control / LibreHardwareMonitor as the mainstream Windows sensor backend —
  <https://github.com/Rem0o/FanControl.Releases>
- PSScriptAnalyzer settings-file and CI guidance —
  <https://github.com/PowerShell/PSScriptAnalyzer>
- Resume-from-sleep triggers: `Power-Troubleshooter` 1 unreliable,
  `Kernel-Power` 107 fires on every resume —
  <https://www.tenforums.com/general-support/75000-power-troubleshooter-not-triggered-wake-sleep.html>
- `PERFBOOSTMODE` / `PERFEPP` semantics for the Turbo plan —
  <https://learn.microsoft.com/en-us/windows-server/administration/performance-tuning/hardware/power/power-performance-tuning>
- CVE-2025-7771 exploitation in the wild; BYOVD mitigation via blocklist + HVCI —
  <https://securelist.com/av-killer-exploiting-throttlestop-sys/117026/>
- Acer chassis fan bearing failure reports —
  <https://community.acer.com/en/discussion/734597/acer-predator-helios-neo-16-sudden-fan-noise-urgent-help-needed>
