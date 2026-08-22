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

## Agent-safe diagnostics

- Ordinary Codex, Claude, and Gemini sessions must not request elevation or query the protected `Acer Adaptive Fan Control` and `Acer Adaptive Fan Watchdog` scheduled tasks directly.
- For routine health, run `src/powershell/fan/Get-AcerFanAgentStatus.ps1`. It consumes the bounded, read-only status, integrity, and watchdog evidence already published under `C:\ProgramData\AcerAdaptiveFanControl`; `privilegedTaskQuery=NOT_ATTEMPTED_BY_DESIGN` is expected.
- A fresh `HEALTHY` result is routine operational evidence, not proof of the protected task definitions. A task-definition audit is an explicit, separately authorized maintenance operation from an already elevated console.
- Do not interpret `UNAVAILABLE` or `ATTENTION_REQUIRED` as permission to mutate tasks, processes, fan state, power settings, drivers, or UAC. Report the stable `reasonCode` and stop that diagnostic branch.
- On Windows, use `rg --glob 'pattern'` or enumerate files before invoking a tool; do not pass an unexpanded wildcard as a literal path. Put non-trivial PowerShell in a checked script and parse it before execution instead of composing nested `foreach`/pipeline one-liners.
- The canonical task names are `Acer Adaptive Fan Control` and `Acer Adaptive Fan Watchdog`. Expected absence of an optional tool is inventory data, not a raw command failure.

## Repository hygiene

- Never commit BitLocker secrets, full device instance IDs, disk serials, usernames, machine names, registry hives, dumps, raw logs, or third-party binaries.
- Store driver versions, hashes, official URLs, decisions, and redacted evidence only.
- Do not use `git add -A`; stage explicit files and inspect the final diff.
- No compatibility claim beyond hardware actually tested.

## Destructive boundaries

- Never delete a boot/storage driver with `/force`.
- Never rebind storage remotely without an off-machine recovery key, dual verified backups, WinRE, a clean reboot state, and physical access.
- Never change BIOS, undervolt, PL1/PL2/PL4, IccMax, voltage, or thermal protections as part of a routine fan/power update.
