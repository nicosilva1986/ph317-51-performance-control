# WMI surface — AcerGamingFunction (PH317-51)

Reference map of the firmware WMI methods used by this project for
fan and sensor control on the Acer Predator PH317-51.

This is not a universal Acer WMI specification. Encodings were
validated on the reference machine (BIOS V1.22, Windows 11 build 26200)
and cross-checked against the Linux `acer-wmi` driver bitfields.
Other models, BIOS versions, or desktop Orion-class firmware may use
different method names or payload layouts.

## Class

```text
Namespace:  root\wmi
Class:      AcerGamingFunction
```

Obtained in PowerShell as:

```powershell
Get-CimInstance -Namespace 'root\wmi' -ClassName 'AcerGamingFunction'
```

## Method IDs (Linux acer-wmi / MOF)

| MethodId | Name | Role in this project |
|---:|---|---|
| 5 | `GetGamingSysInfo` | Sensor reads (temp, RPM) |
| 14 | `SetGamingFanBehavior` | Auto / Turbo-Max / Custom mode |
| 15 | `GetGamingFanBehavior` | Observed mode readback |
| 16 | `SetGamingFanSpeed` | Percent speed when forcing Max |
| 17 | `GetGamingFanSpeed` | Percent read (not required on this path) |

Other methods exist on the class (profile, LED, RGB, misc settings,
overclocking). This project does not call them.

## SetGamingFanBehavior / GetGamingFanBehavior

### Input layout (u64)

Documented by Linux `acer-wmi` (Armin Wolf patches, derived from
Linuwu-Sense reverse engineering):

```text
bits  0–15  fan_bitmap
              BIT(0) = CPU  → 0x0001
              BIT(3) = GPU  → 0x0008
              both         → 0x0009

bits 16–17  CPU mode (2-bit field)
bits 22–23  GPU mode (2-bit field)
```

### Mode values

| Value | Meaning |
|---:|---|
| `0x01` | AUTO |
| `0x02` | TURBO / MAX |
| `0x03` | CUSTOM |

### Values used by this controller

| Action | `gmInput` | Construction |
|---|---|---|
| **MAX** | `0x00820009` | bitmap `0x0009` + CPU mode 2 (`<< 16`) + GPU mode 2 (`<< 22`) |
| **AUTO** | `0x00410009` | bitmap `0x0009` + CPU mode 1 (`<< 16`) + GPU mode 1 (`<< 22`) |
| **CURVE** | `0x00C30009` | bitmap `0x0009` + CPU mode 3 (`<< 16`) + GPU mode 3 (`<< 22`) |

Mode 3 is CUSTOM. It is what makes `SetGamingFanSpeed` carry a real percentage
instead of the fixed 100 % that MAX writes. **The `0x00C30009` payload and the
mode-3 readback have not been exercised on the reference machine yet**; the
controller keeps the proportional band behind `curveEnabled`, which ships false,
until they are. Do not assume they are validated because the code exists.

Success condition: method `gmOutput` status field is `0`.

### Readback

```powershell
GetGamingFanBehavior  gmInput = 0x0009   # same CPU+GPU bitmap
```

Observed compact returns on the reference firmware:

| Raw | Meaning |
|---:|---|
| `256` (`0x0100`) | AUTO |
| `512` (`0x0200`) | MAX |

CPU mode decode used by the controller:

```powershell
$mode = ([uint32]$raw -shr 8) -band 3
# 1 = AUTO, 2 = MAX
```

This matches the Linux `ACER_GAMING_FAN_BEHAVIOR_GET_CPU_MODE_MASK`
(bits 8–9). GPU mode lives in bits 14–15 on the same word; the
controller treats CPU mode as the primary health signal and also
requires both fan RPMs ≥ `minimumMaxRpm` before declaring Max verified.

## SetGamingFanSpeed

### Input layout (u64)

```text
bits 0–7   fan ID
             CPU = 0x01
             GPU = 0x04
bits 8–15  speed percent (0–100)
```

### Values used for Max

| Fan | `gmInput` |
|---|---|
| CPU | `0x00006401` (100 % + ID 0x01) |
| GPU | `0x00006404` (100 % + ID 0x04) |

For the proportional band the same layout carries the commanded percentage:
`(percent << 8) | 0x01` for the CPU fan and `(percent << 8) | 0x04` for the GPU
fan. `0x00003201` is therefore CPU at 50 %. The percent-to-RPM relationship on
this chassis is **unmeasured**, which is why the curve health gate asserts the
firmware mode plus a `curveMinimumVerifiedRpm` floor rather than a predicted RPM.

AUTO does not call `SetGamingFanSpeed`; the firmware restores its
automatic curve after `SetGamingFanBehavior` with mode AUTO.

## GetGamingSysInfo (sensors)

MethodId 5. Input is a sensor command word. Useful magnitude is
typically in the high bits (`raw >> 8` on this machine).

| Sensor | `gmInput` | Notes |
|---|---|---|
| CPU temperature °C | `0x0101` | Validated on reference PH317-51 |
| GPU temperature °C | `0x0A01` | Validated; may read 0 when GPU is powered down |
| System temperature °C | `0x0301` | Validated |
| CPU fan RPM | `0x0201` | Same command used by Linux predator_v4 fan read |
| GPU fan RPM | `0x0601` | Same command used by Linux predator_v4 fan read |

Conversion in the controller:

```powershell
function Convert-GamingSensorValue([uint64] $RawValue) {
    return [int]($RawValue -shr 8)
}
```

Temperature and load validity gates reject out-of-range samples before
any policy decision. Sensor failure fails closed toward MAX.

## Controller call sequence

### Enter / reassert MAX

1. `SetGamingFanBehavior(0x00820009)`
2. `SetGamingFanSpeed(0x00006401)` — CPU 100 %
3. `SetGamingFanSpeed(0x00006404)` — GPU 100 %
4. Reject if any `gmOutput` status ≠ 0
5. Later: require `GetGamingFanBehavior` mode = 2 **and** both RPM ≥ threshold

### Return to AUTO

1. `SetGamingFanBehavior(0x00410009)`
2. Reject if status ≠ 0
3. Later: require mode = 1 on readback

Observed state always beats a successful write return code.

## Alignment with Linux acer-wmi

| Concept | This project | Linux acer-wmi |
|---|---|---|
| Fan bitmap CPU/GPU | `0x0009` | `BIT(0) \| BIT(3)` |
| Modes AUTO / TURBO | `1` / `2` | `ACER_WMID_FAN_MODE_AUTO` / `_TURBO` |
| Fan speed IDs | `0x01` / `0x04` | `ACER_WMID_CPU_FAN` / `_GPU_FAN` |
| RPM sysinfo codes | `0x0201` / `0x0601` | predator_v4 fan speed commands |
| Dual write + status check | yes | status field checked |
| RPM verification gate | yes (≥ 5000 default) | not required by kernel path |

## Comparison to other public clients

### apge-control (Predator Orion desktop)

Uses a **different** method (`SetGamingSysConfig` /
`SetAcerGamingSystemConfiguration`) with a different packing:

```text
0x100FF000004  Auto, front group
0x200FF000004  Auto, rear group
0x100FD000004  Max, front group
0x10046000004  Custom 70 %, front group
```

Mode bytes `0xFF` / `0xFD` and groups `0x100` / `0x200` are not the
notebook `SetGamingFanBehavior` contract. Do not reuse those payloads
on PH317-51.

`GetGamingSysInfo` sensor words were intentionally left unmapped there
after a blind probe hung a machine. This project only uses codes that
were measured on the reference laptop.

### Acer-P-Helper and similar tray apps

Claim `AcerGamingFunction` and expose Auto / Max / Custom as static
profile switches. They do not publish the exact behavior/speed payloads,
do not implement continuous adaptive policy, and do not treat RPM
readback as a health gate. Custom often means “activate the last curve
saved by PredatorSense,” not a live percent write.

## Non-goals of this surface

- Direct embedded-controller register I/O
- Rewriting the percentage on every poll. The curve is quantised to `curveStepPct`
  and damped by a dwell and a falling hysteresis, so writes happen on genuine
  steps, not per sample.
- RGB, LED, overclock, or misc-setting methods
- Assuming the same sensor command words on untested models

## Source pointers

- Controller implementation: `src/powershell/fan/AcerAdaptiveFanController.ps1`
- Policy and verification rules: `docs/architecture.md`
- Linux reference: `drivers/platform/x86/acer-wmi.c` (method IDs 5, 14–17
  and fan behavior/speed bitfields)
- Kernel discussion of behavior packing: acer-wmi fan behavior patches
  (Armin Wolf, 2025), informed by Linuwu-Sense

When extending support beyond PH317-51, re-validate every command word
and return encoding on the new hardware before claiming compatibility.
