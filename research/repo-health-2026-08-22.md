# Repository health assessment — 2026-08-22

Point-in-time review of structure, clarity, and risk. Not a code audit of every CRUW branch.

## Snapshot

| Area | State |
|------|--------|
| Visibility | Private experimental; single validated machine |
| Core product | Fan controller + watchdog + install/deploy |
| Parallel track | CRUW storage-filter maintenance (large) |
| Docs | Strong for a private repo; growing |
| Evidence | Present and linked from README |
| Open issues | ~18 (product + bugs + refactor + research follow-ons) |
| Modularization | Skeleton on `refactor/fan-modules`; **main still monolithic fan scripts** |

## What is healthy

1. **Clear mission** — README states three distinct problems (28×, fan Auto, CRUW) without marketing noise.
2. **Evidence culture** — benchmarks and manifests under `evidence/`; claims tie to JSON.
3. **Safety doctrine** — `AGENTS.md`, `SECURITY.md`, recovery doc; fail-closed fans; no `/force` storage deletes; VBS/HVCI preserved.
4. **WMI documented** — `docs/wmi-surface.md` matches the control plane the code uses.
5. **CI present** — `.github/workflows/ci.yml` exists (parse/simulation oriented; cannot replace live PH317-51).
6. **Issue discipline** — separate tracks for Turbo, CRUW, Custom matrix, telemetry, bugs (#18–#23).

## What hurts understanding

1. **Two products in one repo**
   - Fan path (~25–50 KB scripts) vs CRUW (`CRUWStateMachine.Common.ps1` alone ~150 KB).
   - A new reader cannot tell which tree is “daily driver” vs “maintenance window only” without deep reading.
   - Mitigation: keep `research/` + README explicit; long-term consider `docs/map.md` or splitting packages.

2. **Fan code still monolithic on main**
   - Layout and stubs live on branch `refactor/fan-modules` (`docs/powershell-layout.md` there).
   - Until merge + cutover, `src/powershell/fan/*.ps1` remain the truth — good for stability, bad for onboarding.

3. **Docs link sprawl in README**
   - Many markdown files, no single **map** of “read this first.”
   - Spanish README + English technical docs is fine for the owner; harder for future collaborators.

4. **Issue backlog density**
   - Product roadmap (#2, #9–#15), correctness bugs (#18–#21), CI hygiene (#22), CRUW structure (#23), modularize (#17).
   - Without milestones/labels, priority is tribal knowledge.

5. **CRUW cognitive load**
   - Correct for boot-critical work; still the largest barrier to “I understand this repo in one sitting.”
   - Issue #23 already acknowledges schema-v4 modularization of the state machine.

6. **Branch vs main drift**
   - AGENTS.md says work on branches; research/docs have also landed on main.
   - Harmless for docs; risky if code keeps landing straight to main without review.

## Navigability scorecard (subjective)

| Audience | Can they orient in ≤30 min? |
|----------|-----------------------------|
| Owner (you) | Yes |
| Future self in 6 months | Yes, if research/ + evidence kept current |
| External reviewer (public release) | Partially — needs map, license, fewer monoliths (#5) |
| Someone running only fans | Yes via `docs/usage.md` + fan scripts |
| Someone running CRUW | Only with `docs/recovery-and-rollback.md` + physical checklist |

## Recommended clarity fixes (docs-only, low risk)

- [x] Add `research/` for platform context (this folder).
- [ ] Add `docs/map.md` (one page: fan vs maintenance vs research vs evidence).
- [ ] Merge or cherry-pick `docs/powershell-layout.md` to main when ready so layout is not branch-only.
- [ ] Label issues: `fan`, `cruw`, `bug`, `research`, `release`.
- [ ] Pin “current recommended read order” at top of README (5 links max).

## Recommended engineering order (unchanged intent)

```text
Correctness bugs affecting live fan path (#18, #19, #21)
  → modularize fan (#17)
  → native Turbo (#2) + limit telemetry (#9)
  → Custom matrix (#10) before graduated policy
  → CRUW only in a planned physical window (#3, #23)
```

## Bottom line

The repository is **healthy as a private evidence-led lab**: principles are coherent, measurements exist, and dangerous operations are documented. It is **not yet easy** as a multi-contributor or public codebase: size of CRUW, monolithic fan scripts, and issue sprawl are the main comprehension taxes—not lack of purpose.
