# `powercfg` fails on a healthy power configuration (2026-08-24)

**Status:** root cause identified, **deliberately not fixed**. The power policy
is already correct; only the tooling that displays it is broken.

**Symptom:** `powercfg /getactivescheme` and `powercfg /query` exit 1 with
"El plan, subgrupo o configuración de energía especificado no existe"
(*The specified power plan, subgroup or setting does not exist*), and
`powercfg /list` prints a single scheme GUID with no friendly name.

It reads exactly like a destroyed power configuration. It is not one.

---

## 1. The configuration is intact

Read straight out of the registry, then confirmed through
`PowerReadACValueIndex`, which returns effective values without going near
name resolution:

| Setting | Effective value | Meaning |
|---------|-----------------|---------|
| Active scheme | `381b4222-…` | Balanced |
| `PROCTHROTTLEMIN` | 5 % | idle drops to LFM — stays cool |
| `PROCTHROTTLEMAX` | 100 % | full clock available |
| `PERFBOOSTMODE` | 2 | turbo Aggressive |
| `SYSCOOLPOL` | 1 | active cooling |

`HKLM\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes` holds all seven
schemes with correct `FriendlyName` values, and `…\Power\PowerSettings` has 23
subgroups including the processor one with 95 settings. Only `PERFBOOSTMODE`
exists as a per-scheme override; the rest resolve to system defaults, which are
already the wanted values.

## 2. Where it actually breaks

`powercfg` obtains the active scheme successfully, then calls
`PowerReadFriendlyName`, which resolves the indirect string
`@%SystemRoot%\system32\powrprof.dll,-15,Balanced` through
`SHLoadIndirectString`. That call fails, and `powercfg` treats the failure as
fatal for the whole operation.

Verified directly rather than inferred:

```
@%SystemRoot%\system32\powrprof.dll,-15,Balanced   hr=0x80004005   FAIL
@%SystemRoot%\system32\powrprof.dll,-13            hr=0x80004005   FAIL
@shell32.dll,-21770                                hr=0x00000000   "Documentos"
```

Indirect-string resolution works in general. It fails **only for
`powrprof.dll` resources**.

## 3. Root cause: a servicing version mismatch

MUI resource files are validated against the binary they belong to. These do
not match:

| File | Version |
|------|---------|
| `System32\powrprof.dll` | **10.0.26100.8875** |
| `System32\es-MX\powrprof.dll.mui` | **10.0.26100.8117** |
| `System32\shell32.dll` | 10.0.26100.8972 |
| `System32\es-MX\shell32.dll.mui` | 10.0.26100.8972 |

A cumulative update replaced `powrprof.dll` and left the localised resource
file behind, so the loader refuses it. `shell32`, whose pair matches, resolves
fine — which is why the failure looks selective. `System32\es-MX\powercfg.exe.mui`
is missing outright, and the machine carries a partial `es-ES` resource set
(789 files) alongside the active `es-MX` one.

This is a Windows servicing defect on non-`en-US` language configurations. No
local change caused it, and no registry tweak can be blamed for it.

## 4. Why it was left alone

The obvious repair, `powercfg -restoredefaultschemes`, **would make the machine
slower**: it wipes per-scheme overrides, including the `PERFBOOSTMODE = 2` that
is currently giving aggressive turbo. Rebuilding a healthy configuration to fix
a cosmetic string lookup is a bad trade.

The commonly suggested workaround — replacing `FriendlyName` with a plain
`REG_SZ` string — does restore `powercfg` exit codes, but only for the scheme
edited. Every other `powrprof` string stays broken, and the hardcoded name
breaks again if the display language changes.

The real fix, if `powercfg` is ever needed for diagnosis, is to repair the
component store so the matching MUI is restored:

```
DISM /Online /Cleanup-Image /RestoreHealth
sfc /scannow
```

Neither touches configuration; they only replace system files.

## 5. Reading for whoever hits this next

- Power **policy** is fine; power **tooling** is not. Do not infer corruption
  from a `powercfg` error.
- Read effective values with `PowerReadACValueIndex`, not by parsing
  `powercfg` output. Tooling that parses console text is exactly what breaks
  here.
- Before "repairing" anything, dump the per-scheme overrides that actually
  exist under the scheme key. Losing `PERFBOOSTMODE` is silent and costs turbo.

Relevant to this project because the power plan is one of the few remaining
thermal levers, and an apparently broken one invites exactly the kind of
destructive repair that would have undone a working setup.
