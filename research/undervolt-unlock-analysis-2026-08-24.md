# Reviewing a proposed BIOS unlock for undervolting (2026-08-24)

**Status:** analysed, **not attempted**. The proposal targets the wrong lock for
this machine, and the measurement that shows why is a two-line registry read.

Context: a third-party analysis proposed unlocking CPU undervolting by flipping
a hidden firmware setup variable. It arrived as a working document with
extracted BIOS volumes and IFR parsing. This note records what was checked, what
held up, and what did not — the underlying question is already closed in
[undervolt-effectiveness-2026-08-24.md](undervolt-effectiveness-2026-08-24.md).

---

## The proposal

- **Claim:** CFG Lock (`MSR 0xE2` bit 15) is what stops ThrottleStop's offset
  from reaching the silicon.
- **Method:** decompress the Insyde H2O volumes, parse the IFR forms, resolve
  the HII strings, and read out the setup-variable offset behind the hidden
  "CFG Lock" option.
- **Procedure:** boot `modGRUBShell.efi` and run `setup_var_3 0x17B 0x00`, then
  re-apply the offset in ThrottleStop.

The method is legitimate — IFR extraction plus `setup_var` is the established
community route on Insyde laptops, and the board identification checks out
(Sienna_KLS, HM175, BIOS V1.22, CPUID `0x906E9`, all confirmed locally).

## Why it does not apply here

### 1. Wrong lock

CFG Lock governs `MSR 0xE2`, the package C-state configuration. The voltage
offset lives behind the FIVR mailbox at `MSR 0x150`. These are different gates.
The proposal's own section 1 says two gates must be open — CFG Lock **and**
Overclocking Lock (`MSR 0x194` bit 20) — and then supplies an offset for only
the first. The gate that actually governs voltage is missing from the table.

### 2. The real blocker is microcode, and it is reapplied every boot

```
Update Revision           0xDE   <- running now, loaded by Windows
Previous Update Revision  0x9A   <- what BIOS V1.22 ships
```

(`HKLM\HARDWARE\DESCRIPTION\System\CentralProcessor\0`.)

BIOS V1.22 dates from 2019-03 and carries microcode `0x9A`, which predates the
CVE-2019-11157 mitigation. Windows loads `0xDE` at every boot through
`mcupdate_GenuineIntel.dll`, and that revision contains the mitigation that
makes writes to the voltage mailbox a silent no-op.

So a setup-variable change cannot fix this: whatever the firmware permits, the
OS reapplies the mitigating microcode before Windows starts. This is consistent
with the local measurement — VID flat at a fixed 28x multiplier across a month
spanning the change — which shows the *effect* without naming the mechanism.

### 3. The one path that probably would work, and why it was rejected

Because the BIOS microcode is pre-mitigation, preventing the OS runtime update
would likely leave the mailbox open. That trades every microcode fix since 2019
— errata and security both, not only Plundervolt — for roughly 100 mV on a
machine whose only demonstrated thermal lever is the fan overlay. Declined.

## Risk note on `setup_var`

`setup_var` writes a raw byte at an offset inside an NVRAM variable. If the
varstore or offset is off — and the offsets here come from the proposal's own
parse, unverified independently — the write lands on an unrelated setting. The
`_3` suffix selects a different varstore than plain `setup_var`, so picking
wrong is easy. Recovery from a bad NVRAM state on this chassis can mean
disassembly to disconnect the battery. Any future attempt should read first
(`setup_var_3 0x17B` with no value) and confirm the offset against a second,
independent parse before writing anything.

## Cheap check nobody has run yet

ThrottleStop's FIVR window reports CFG Lock and Overclocking Lock status
directly. If CFG Lock already shows unlocked, the proposal's premise fails with
no risk taken at all. Worth thirty seconds before anyone spends an evening on
`setup_var`.

## Conclusion

Undervolting stays closed on this machine, for the reason already recorded: the
mitigation lives in microcode `0xDE`, not in a firmware setup variable. The fan
overlay remains the only measured lever.
