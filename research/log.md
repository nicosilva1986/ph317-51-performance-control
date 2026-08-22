# Research log

Append-only. Newest entries at the top.

## 2026-08-22 — Cross-vendor control landscape

- Question: CPU/GPU behaviour and solutions on other brands; are we missing an approach?
- Conclusion: heat is genre-wide; **PH317-51 bottleneck remains Acer platform policy**. Solution schools are (1) official WMI/ACPI (G-Helper, LLT, Acer-P-Helper, us) vs (2) EC poke (NBFC, WinRing0). No better public stack for this SKU with fail-closed + evidence + native turbo.
- Borrow as product ideas only: composite AC/DC profiles, predictive dT/dt, Cooler-Boost-style MAX overlay, GPU telemetry — stay on WMI.
- Captured in `cross-vendor-control-landscape.md`.

## 2026-08-22 — Platform vs micro; multi-language forum sweep

- Question: is the need for this project the 7700HQ or Acer?
- Conclusion: silicon is expected-hot H-series; **Acer cooling + Auto fan policy** are the platform drivers; reference machine adds ThrottleStop 28× and aging hardware.
- Captured in `platform-thermal-context.md` + `forum-sources.md`.
- Languages touched: EN (Acer Community, TechRadar, LaptopMedia), DE (Acer Community), PL (Notebookcheck/PurePC), RO (mygarage), ES (Geeknetic).
- Local evidence already on main: Auto vs Max FMA JSON under `evidence/benchmarks/`.

## 2026-08-22 — Repo health pass

- Written `repo-health-2026-08-22.md`: strengths (evidence, fail-closed, docs, security posture) and friction (CRUW monolith size, fan modularization not cut over, issue backlog, docs discoverability, branch `refactor/fan-modules` not merged).
