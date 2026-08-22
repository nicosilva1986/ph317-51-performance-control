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
- a recent restore point exists for the temporary maintenance window;
- exported CRU INF/SYS/CAT and SYSTEM hive exist in two verified local locations;
- no pending reboot state;
- the user confirms the 48-digit BitLocker recovery key is available **off the notebook** without pasting it into any chat/log.

Sequence after a clean preliminary restart:

1. Re-run preflight and require all gates green.
2. Suspend C: BitLocker protectors for exactly two boots.
3. Run `pnputil /delete-driver <preflight-sealed-published-name> /uninstall` without `/force`; never assume the OEM number remains `oem127.inf`.
4. Verify volumes remain present and require either a completely clean native state or a completely intact legacy state. **Do not restart a mixed state.** In particular, no `CRUWBlocker` device/class filter reference may remain if its service/package/binary is absent; Microsoft documents that mismatch as a possible `INACCESSIBLE_BOOT_DEVICE` / `0x7B` cause.
5. Only a clean state—both devices rebound, no CRUW filter references, and native storage components preserved—may proceed to a deliberate restart.
6. Postboot verify both disks use Microsoft `disk.inf`, no per-device `CRUWBlocker` lower filter remains, the service is absent, disks are healthy and there are no new storage/WHEA errors.
7. Re-enable BitLocker and verify Protection On.
8. Restore the user's prior maintenance settings: System Restore and WinRE may be disabled again only after successful validation. Disabling System Restore deletes provisional restore points.

Never attempt this remotely without an off-machine recovery key and physical access.
