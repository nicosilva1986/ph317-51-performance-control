# Recovery and rollback

## General rule

Recovery material remains local and excluded from Git. The repository records procedures and hashes, never secrets or raw registry hives.

## Fan controller

Before replacing a running version:

1. Parse and validate scripts/configuration.
2. Pin expected SHA-256 values.
3. Request firmware `MAX` and verify it.
4. Preserve previous files/tasks.
5. Install into a protected versioned directory.
6. Start controller and watchdog.
7. Require bounded semantic health (`HEALTHY_VERIFIED`, expected state/mode/RPM), exact task principal/action and recursive ACL validation.
8. On any failure, roll back to the prior version or leave hardware in `MAX`; never silently continue in Auto.

## CRU disk-filter correction

The current binding is boot-critical and requires a physical maintenance window.

Go/no-go conditions:

- AC power connected;
- both physical disks healthy;
- WinRE enabled and location valid;
- the exact latest positive-sequence restore point is the named maintenance checkpoint and is recent;
- exported CRU INF/SYS/CAT and SYSTEM hive exist in two verified local locations;
- every mounted encrypted volume is fully encrypted, Protection On, unlocked, at 100%, and has at least one recovery-password protector;
- no pending reboot state;
- the user confirms the 48-digit BitLocker recovery key is available **off the notebook** without pasting it into any chat/log.

Schema v3 packages the producer, preflight core, common state machine, removal executor, interruption repair and postboot validator. Their ordered roles and SHA-256 hashes are repeated in both `preflight.json` and the byte-identical dual manifests. The producer creates fresh non-reparse roots under protected SYSTEM/Administrators-only parents, rejects extra files/directories/alternate streams, and cross-checks the physical INF/SYS/CAT bytes against all three signed known-package hashes both before and after final serialization. A schema-v2 bundle is not eligible.

Sequence after a clean preliminary restart and a fresh schema-v3 preflight:

1. Re-run preflight and require all gates green.
2. Suspend C: BitLocker protectors for exactly two boots.
3. Run `pnputil /delete-driver <preflight-sealed-published-name> /uninstall` without `/force`; never assume the OEM number remains `oem127.inf`.
   Only documented process exit codes `0` (success) and `3010` (success, restart required) are eligible to continue, and only when the independent live inventory also proves the exact clean state. Exit code `259` (no matching or better driver), `1641` (restart initiated), or any other value enters a protected diagnostic hold and cannot produce `REBOOT_AUTHORIZED`. Because this workflow never passes `/reboot`, `1641` also proves that the invocation contract was violated. Preserve and hash the relevant `%SystemRoot%\inf\setupapi.dev.log` evidence for diagnosis; never infer success from a non-zero code or log text alone.
4. Verify volumes remain present and require either a completely clean native state or a completely intact legacy state. **Do not restart a mixed state.** In particular, no `CRUWBlocker` device/class filter reference may remain if its service/package/binary is absent; Microsoft documents that mismatch as a possible `INACCESSIBLE_BOOT_DEVICE` / `0x7B` cause.
5. Only a clean state—both devices rebound, no CRUW filter references, and native storage components preserved—may proceed to a deliberate restart.
6. Postboot verify both disks use Microsoft `disk.inf`, no per-device `CRUWBlocker` lower filter remains, the service is absent, disks are healthy and there are no new storage/WHEA errors.
7. Re-enable BitLocker and verify Protection On. The first all-green postboot result is a stability checkpoint, not final maintenance completion.
8. Keep WinRE and System Restore enabled through a later distinct stable boot. Only a separate, explicit finalization run may restore an original `Disabled` state that was sealed from an explicit user declaration. An `Unknown` baseline is never inferred or disabled. Disabling System Restore deletes provisional restore points.

The transaction uses immutable, hash-linked journal entries on C: and D:. A checkpoint is committed only when both copies are byte-identical and ACL-protected. A one-sided tail is forensic evidence, never authority to repeat deletion or reboot. The repair entrypoint classifies current storage state and **never replays** `/delete-driver`: intact legacy state closes safely, clean preboot state can be revalidated for a manual reboot, and mixed state can use a separately revalidated backup for rollback. Closed terminal states are idempotent.

System Restore readiness is revalidated independently: the producer requires a queryable exact latest checkpoint plus both `DisableSR` signals not set. `DisableConfig` is retained as evidence but is not treated as “System Restore off,” because Microsoft defines it as the policy that disables the configuration interface rather than restore operation itself.

The signed INF declares the CRUW service as demand-start (`StartType=3`), while the live reference service is boot-start (`Start=0`). Archived local SetupAPI logs contain nine repeated observations that Windows promoted this exact service to boot-start during device reflection; the sanitized hashes and counts are recorded in [`evidence/manifests/cruw-rollback-promotion-2026-08-22.json`](../evidence/manifests/cruw-rollback-promotion-2026-08-22.json). That history is diagnostic evidence sufficient only to make one sealed-package rollback attempt; it is not authority and does not guarantee restoration. Rollback succeeds only if a fresh live readback proves the exact boot-start, running service, no `StartOverride`, canonical system driver path and original filter bindings. The workflow never edits the service or registry to manufacture that result.

There are two human gates: authorization immediately before the preliminary clean restart, then a separate authorization immediately before the boot-critical removal window. No script invokes a reboot primitive. `REBOOT_AUTHORIZED` permits exactly one deliberate manual restart; absent that dual-committed checkpoint, the instruction is `DO NOT REBOOT`.

Postboot validation always verifies storage, C:/D: read/write/hash/delete probes, native controller chains, storage/WHEA events and BitLocker Protection On. A red diagnostic enters a protected hold; it never reports completion merely because the machine booted. A green first boot enters `POSTBOOT_STABILITY_PENDING`; recovery settings are not restored until a later stable boot and separate confirmation.

Never attempt this remotely without an off-machine recovery key and physical access. For the underlying platform behavior, see Microsoft's [PnPUtil syntax](https://learn.microsoft.com/en-us/windows-hardware/drivers/devtest/pnputil-command-syntax), [PnPUtil return values](https://learn.microsoft.com/en-us/windows-hardware/drivers/devtest/pnputil-return-values), [SetupAPI text logs](https://learn.microsoft.com/en-us/windows-hardware/drivers/install/setupapi-text-logs), [bounded BitLocker suspension guidance](https://learn.microsoft.com/en-us/troubleshoot/windows-client/windows-security/suspend-bitlocker-protection-non-microsoft-updates), [REAgentC options](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/reagentc-command-line-options?view=windows-11), [`Enable-ComputerRestore`](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/enable-computerrestore?view=powershell-5.1), [`Get-ComputerRestorePoint`](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/get-computerrestorepoint?view=powershell-5.1), [System Restore policies](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-admx-systemrestore), and [`INACCESSIBLE_BOOT_DEVICE` / 0x7B storage-filter troubleshooting](https://learn.microsoft.com/en-us/troubleshoot/windows-client/performance/stop-error-7b-or-inaccessible-boot-device-troubleshooting).
