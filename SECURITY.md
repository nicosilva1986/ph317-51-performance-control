# Security policy

## Privileged boundary

The controller and watchdog run as `SYSTEM`. Source/configuration used by a privileged task must not be writable by a standard user. Installation must:

1. validate expected SHA-256 hashes before elevation and again inside the protected boundary;
2. stage into a protected directory;
3. apply and recursively verify ACLs by SID;
4. keep the previous known-good version until health verification succeeds;
5. force firmware fan mode to `MAX` before stopping existing guardians;
6. roll back or leave `MAX` active on every failure path.

`Administrators` and `SYSTEM` remain authoritative. The tool can prevent accidental drift and ordinary-user replacement; it cannot make a Windows administrator, firmware, or the embedded controller powerless.

## ThrottleStop driver

The reference computer loaded signed `ThrottleStop.sys` version `3.0.0.0` with SHA-256:

```text
16F83F056177C4EC24C7E99D01CA9D9D6713BD0497EEEDB777A3FFEFA99C97F0
```

That exact version is identified by [CVE-2025-7771](https://nvd.nist.gov/vuln/detail/CVE-2025-7771). This repository does not redistribute it and does not use it as permanent infrastructure. The target design uses native Intel/Windows performance control with VBS/HVCI left enabled.

## Sensitive evidence

Never commit:

- BitLocker recovery passwords or protector material;
- complete PnP instance IDs, disk serial numbers, user names, or machine names;
- registry hives, dumps, ETL files, raw support bundles, or unreviewed logs;
- third-party EXE/MSI/SYS/CAT/CAB/ZIP files.

Commit only redacted metadata, official source URLs, versions, hashes, and reproducible summaries.
