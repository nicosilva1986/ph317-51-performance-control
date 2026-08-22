# Hardware and driver baseline — 2026-08-21

This document is redacted for publication. Full device identifiers and recovery artifacts remain local.

## Reference platform

| Component | Observed state |
|---|---|
| Laptop | Acer Predator PH317-51 |
| CPU | Intel Core i7-7700HQ, 4C/8T |
| GPU | NVIDIA GeForce GTX 1060 + Intel HD Graphics 630 |
| RAM | 16 GB, 2×8 GB DDR4-2667 |
| OS | Windows 11 build 26200 |
| BIOS | V1.22; Acer catalog checked at V1.21, therefore no downgrade |
| NVMe | Crucial P3 Plus, firmware P9CR413, healthy |
| Secondary disk | WDC 1 TB HDD, healthy |

Windows reported 223 present PnP devices and zero devices in an error state. Microsoft Update returned no pending compatible driver updates at the time of the audit.

## Retained compatible branches

| Device | Version | Decision |
|---|---:|---|
| Intel HD Graphics 630 | 31.0.101.2141 | Keep |
| NVIDIA GTX 1060 | 582.66 | Keep |
| Realtek GbE | 10.80.50.407 | Keep |
| Qualcomm QCA61x4A Wi-Fi/Bluetooth | 12.0.0.1272 | Keep |
| Realtek HDA/SST | 6.0.9273.1 | Keep; hardware-matched |
| Intel SST | OEM-matched | Keep |
| Micron NVMe | 2.1.19.0 | Keep; hardware-matched |

"Higher version number" alone is not a compatibility proof. OEM audio/SST, ACPI and storage stacks must match hardware IDs and firmware topology.

## Incorrect inherited bindings found

1. **CRU USB 3.0 WriteBlocker 1.2.1.1** (`oem127.inf`) was a `BOOT_START` lower filter on both internal disks, despite no CRU forensic write-blocker hardware being present. Correct target: Microsoft `disk.inf`. Removal remains gated by offline BitLocker-key confirmation, dual backups, WinRE, a clean preliminary reboot and postboot disk validation.
2. **Surface ACPI Battery 1.2.20** (`oem129.inf`) was bound to the Acer battery node. Candidate correction: Microsoft `cmbatt.inf`, separately validated.
3. **Alps/Lenovo Keyboard 1.0.0.2** (`oem164.inf`) was bound to the Acer internal keyboard and loaded `ApkbfiltrService`. Candidate correction requires physical testing of keyboard, Fn keys and backlight before package removal.

## PredatorSense decision

The exact Acer PH317-51 package found was PredatorSense 2.01.3005, SHA-256:

```text
CBBFCD6200BA9F29CC1D431F6ADAF74036FCB9A4F3063EAD6C3D7AC5A9C5C6E0
```

It was not installed because its default feature set also carries legacy Intel XTU/kernel components. The existing firmware interface was sufficient for direct, reversible fan control without installing that legacy stack.
