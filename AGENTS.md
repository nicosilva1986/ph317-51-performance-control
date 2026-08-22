# Repository operating rules

This project controls privileged thermal, power, and driver state. Evidence and rollback are part of the implementation, not optional documentation.

## Before changes

- Confirm the exact laptop model, BIOS, Windows build, CPU, and presence of `AcerGamingFunction`.
- Work on a branch; do not push directly to `main` after the bootstrap commit.
- Capture the current controller/task/power/driver state without exposing secrets.
- Keep VBS/HVCI, UAC configuration, BitLocker, BD PROCHOT, and firmware protections unchanged unless the user explicitly approves that separate security decision.

## Code and tests

- Use one privileged writer per hardware control plane.
- Invalid telemetry, state, integrity, or heartbeat must fail toward maximum cooling.
- Do not claim a successful write without readback evidence.
- Installation/upgrades must be transactional and recover the previous known-good version or leave fans in Max.
- Unit/simulation tests must isolate each trigger. Real hardware claims require real readback, RPM, thermal samples, workload output, WHEA review, and a final process/task check.
- A timeout, running process, green empty test, or planned validation is not a pass.

## Repository hygiene

- Never commit BitLocker secrets, full device instance IDs, disk serials, usernames, machine names, registry hives, dumps, raw logs, or third-party binaries.
- Store driver versions, hashes, official URLs, decisions, and redacted evidence only.
- Do not use `git add -A`; stage explicit files and inspect the final diff.
- No compatibility claim beyond hardware actually tested.

## Destructive boundaries

- Never delete a boot/storage driver with `/force`.
- Never rebind storage remotely without an off-machine recovery key, dual verified backups, WinRE, a clean reboot state, and physical access.
- Never change BIOS, undervolt, PL1/PL2/PL4, IccMax, voltage, or thermal protections as part of a routine fan/power update.
