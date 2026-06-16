# Task 3.3 IPC Summary: 50M Warmup + 100M Simulation

## Erratum: Stale NoPF LRU/MockingJay Binaries

This 50M/100M run was later found to include stale no-prefetch LRU and
MockingJay binaries. The affected binaries still linked the old
`PageMigrationEngine::recordAccess(uint64_t)` symbol instead of the fixed
`recordAccess(uint64_t, bool)` interface.

Affected rows:

- `Rnd+Fwd+NoPF`: LRU and MockingJay
- `Rnd+Bwd+NoPF`: LRU and MockingJay

Symptom:

- For LRU and MockingJay, `Rnd+Nomig+NoPF`, `Rnd+Fwd+NoPF`, and
  `Rnd+Bwd+NoPF` produced identical per-workload IPC values.
- The affected raw logs contain only the migration init line
  (`[migration] mode=forward/backward`) and no migration action lines
  (`[migration] forward #...` / `[migration] backward #...`).

Status:

- Binaries were rebuilt in
  `artifacts/runs/task3.3-build-binaries/20260616-201601`.
- `nm -C` verification confirms all 12 task3.3 binaries now use
  `PageMigrationEngine::recordAccess(unsigned long, bool)`.
- The affected 50M/100M cells were rerun in
  `artifacts/runs/task3.3-cross-compare-repair/20260616-202411`.
- The repair run completed 48 pass / 0 fail, and every repaired run emitted
  migration action lines.
- The formal 50M warmup + 1B simulation batch should be treated as a separate
  program window with independently generated first-1050M area maps.

## Run Metadata

| Item | Value |
|------|-------|
| Run directory | `artifacts/runs/task3.3-cross-compare/20260616-174339` |
| Repair run directory | `artifacts/runs/task3.3-cross-compare-repair/20260616-202411` |
| Workloads | 12 |
| Configurations | 10 |
| Policies | `lru`, `mockingjay`, `rpp` |
| Total original tasks | 360 |
| Original completion | 360 pass / 0 fail |
| Repaired cells | 48 |
| Repair completion | 48 pass / 0 fail |
| Warmup | 50M instructions |
| Simulation | 100M instructions |
| Area maps | `artifacts/runs/task3.1-gen-areamaps/20260616-154756` |
| Area-map window | first 150M instructions |
| DRAM:CXL page ratio | fixed 1:2 |

## Corrected Geomean IPC

Each value is the geometric mean over the 12 selected workloads. The
`Rnd+Fwd+NoPF` and `Rnd+Bwd+NoPF` LRU/MockingJay values below use the repair
run outputs, overriding the stale-binary values from the original full run.

| Config | LRU | MockingJay | RPP |
|---|---:|---:|---:|
| Rnd+Nomig+NoPF | 0.546404 | 0.692768 | 0.725496 |
| Sort+Nomig+NoPF | 0.710338 | 0.811871 | 0.826809 |
| FCFS+Nomig+NoPF | 0.567226 | 0.682910 | 0.705363 |
| Rnd+Fwd+NoPF | 0.591451 | 0.697080 | 0.707309 |
| Rnd+Bwd+NoPF | 0.614680 | 0.731192 | 0.739493 |
| Rnd+Nomig+IPCP | 0.645046 | 0.881942 | 0.902083 |
| Rnd+Nomig+IPstride | 0.736051 | 0.904009 | 0.927122 |
| Rnd+Nomig+BothPF | 0.743728 | 0.990138 | 1.004306 |
| FCFS+Bwd+BothPF | 0.824507 | 1.036181 | 1.036435 |
| Sort+Fwd+BothPF | 0.824527 | 1.027115 | 1.028982 |

## Corrected Speedup Normalized to LRU

For each row, the corresponding LRU geomean IPC is normalized to 1.0000.

| Config | MJ / LRU | RPP / LRU | RPP / MJ |
|---|---:|---:|---:|
| Rnd+Nomig+NoPF | 1.2679 | 1.3278 | 1.0472 |
| Sort+Nomig+NoPF | 1.1429 | 1.1640 | 1.0184 |
| FCFS+Nomig+NoPF | 1.2039 | 1.2435 | 1.0329 |
| Rnd+Fwd+NoPF | 1.1786 | 1.1959 | 1.0147 |
| Rnd+Bwd+NoPF | 1.1895 | 1.2031 | 1.0114 |
| Rnd+Nomig+IPCP | 1.3673 | 1.3985 | 1.0228 |
| Rnd+Nomig+IPstride | 1.2282 | 1.2596 | 1.0256 |
| Rnd+Nomig+BothPF | 1.3313 | 1.3504 | 1.0143 |
| FCFS+Bwd+BothPF | 1.2567 | 1.2570 | 1.0002 |
| Sort+Fwd+BothPF | 1.2457 | 1.2480 | 1.0018 |

## Main Observations

1. RPP is above MockingJay in corrected geomean IPC for all 10 configurations, but the margin depends strongly on whether prefetching and migration are enabled.

2. The largest RPP-over-MJ gains appear in the no-prefetch settings:
   - `Rnd+Nomig+NoPF`: RPP/MJ = 1.0472
   - `FCFS+Nomig+NoPF`: RPP/MJ = 1.0329
   - `Sort+Nomig+NoPF`: RPP/MJ = 1.0184

3. After repairing the stale LRU/MockingJay migration binaries, the affected
   random-migration rows no longer collapse to the no-migration baseline:
   - `Rnd+Fwd+NoPF`: LRU 0.546404 -> 0.591451; MockingJay 0.692768 -> 0.697080
   - `Rnd+Bwd+NoPF`: LRU 0.546404 -> 0.614680; MockingJay 0.692768 -> 0.731192

4. With both prefetchers enabled, RPP and MockingJay become much closer:
   - `Rnd+Nomig+BothPF`: RPP/MJ = 1.0143
   - `FCFS+Bwd+BothPF`: RPP/MJ = 1.0002
   - `Sort+Fwd+BothPF`: RPP/MJ = 1.0018

5. The best absolute geomean IPC in this corrected 50M/100M summary is `FCFS+Bwd+BothPF`:
   - LRU = 0.824507
   - MockingJay = 1.036181
   - RPP = 1.036435

6. `Sort+Fwd+BothPF` is close to `FCFS+Bwd+BothPF`, but slightly lower in RPP geomean IPC:
   - `FCFS+Bwd+BothPF` RPP = 1.036435
   - `Sort+Fwd+BothPF` RPP = 1.028982
   - Relative difference: `FCFS+Bwd+BothPF` is about 0.72% higher.

7. Offline sort placement improves the no-prefetch no-migration baseline over random placement for all three policies. For example:
   - LRU: 0.710338 vs 0.546404
   - MockingJay: 0.811871 vs 0.692768
   - RPP: 0.826809 vs 0.725496

8. This summary only covers the first independent program window: 50M warmup + 100M simulation, with area maps generated from the first 150M instructions. The 50M warmup + 1B simulation run should use separately generated area maps from the first 1050M instructions and should be summarized separately.
