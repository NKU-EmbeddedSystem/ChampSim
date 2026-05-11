# Profiling Pipeline for Per-PC Assembly Context + Ground Truth Labels

Automates the full data collection workflow for training a per-PC prefetch policy
prediction model. Built on top of ChampSim + Intel PIN + SPEC CPU2006 + DPC-3 SimPoints.

## Overview

```
  SPEC binary (.o2)
       │
       ├──→ objdump -d ──→ parse_disassembly.py ──→ PC→instruction index
       │
       └──→ PIN tracer (per SimPoint interval) ──→ trace .xz files
                │
                └──→ ChampSim + HINT_PROFILING (per prefetcher×degree)
                         │
                         └──→ per-PC AMAT records
                                  │
                                  │  cross-prefetcher comparison
                                  ▼
                         best_prefetch label per PC
                                  │
                                  │  + assembly context
                                  ▼
                         instruction-tuning dataset
```

## Prerequisites

| Component | Version | How to get |
|-----------|---------|------------|
| SPEC CPU2006 | source + license | `~/cpu2006` (compiled with `runspec`) |
| Intel PIN | 3.22+ | `wget https://software.intel.com/sites/landingpage/pintool/downloads/pin-3.22-98547-g7a303a835-gcc-linux.tar.gz` |
| ChampSim | with hint_dispatch | `./config.sh champsim_config_hint_profile.json && make` |
| DPC-3 SimPoints | tarball | Download `weights-and-simpoints-speccpu.tar.gz` from DPC-3 website |
| Python 3.8+ | stdlib only | None |

## Quick Start

### 1. One-shot environment setup

```bash
./setup.sh
```

This handles: SPEC config generation → SPEC benchmark compilation → PIN download & install → ChampSim tracer build → ChampSim binary build.

Or run individual steps:
```bash
./setup.sh --step A    # SPEC config only
./setup.sh --step B    # Compile benchmarks
./setup.sh --step C    # PIN install
```

### 2. Run the pipeline

```bash
# Setup + full pipeline for 400.perlbench:
./run_pipeline.sh 400.perlbench --setup

# Setup only (no benchmark):
./run_pipeline.sh --setup-only

# Single stage:
./run_pipeline.sh 400.perlbench --stage 2

# Dry-run to preview commands:
./run_pipeline.sh 400.perlbench --dry-run
```

## Pipeline Stages

### Stage 1: Parse SimPoints
Reads the DPC-3 SimPoints tarball, extracts intervals + weights for the target
benchmark, saves as `data/{benchmark}/simpoints.json`.

```
Input:  weights-and-simpoints-speccpu.tar.gz
Output: data/{benchmark}/simpoints.json
```

### Stage 2: Disassembly
Locates the compiled SPEC binary, runs `objdump -d`, parses the output into a
structured PC→instruction index.

```
Input:  ~/cpu2006/benchspec/CPU2006/{benchmark}/run/run_base_*/{exe}
Output: data/{benchmark}/disasm_index.json
```

### Stage 3: Trace Generation
For each SimPoint interval with weight ≥ threshold, runs PIN with ChampSim
tracer to generate a `.champsimtrace.xz` file.

Uses `-s` (skip) = `interval_id × 100M` and `-t` (trace length) = `100M`.

```
Input:  simpoints.json, SPEC binary
Output: data/{benchmark}/traces/{benchmark}-{interval}B.champsimtrace.xz
```

### Stage 4: Profiling
For each trace × prefetch policy × degree, runs ChampSim with HINT_PROFILING
to record per-PC AMAT.

```
Input:  traces/*.xz
Output: data/{benchmark}/profiling/{trace}__{prefetcher}__{degree}.json
```

### Stage 5: Assembly Context
Reads trace to extract unique Load PCs, then queries the disassembly index
to capture surrounding instructions (±N).

```
Input:  disasm_index.json, traces/*.xz
Output: data/{benchmark}/assembly_context.jsonl
```

### Stage 6: Ground Truth Aggregation
Cross-references all profiling runs, compares AMAT per PC across prefetchers,
produces `best_prefetch` label for each PC.

```
Input:  profiling/*.json
Output: data/{benchmark}/ground_truth.jsonl
```

### Stage 7: Training Dataset
Merges assembly context with ground truth labels into a unified
instruction-tuning format.

```
Input:  assembly_context.jsonl, ground_truth.jsonl
Output: data/{benchmark}/tuning_dataset.jsonl
```

## Output Formats

### simpoints.json
```json
[
  {"interval_id": 210, "weight": 0.481},
  {"interval_id": 1273, "weight": 0.257}
]
```

### disasm_index.json
```json
{
  "function_names": ["Perl_pp_add", "main"],
  "instructions": {
    "0x4c36e6": {
      "pc_hex": "0x4c36e6",
      "mnemonic": "push",
      "operands": "%rbp",
      "full_text": "push %rbp",
      "function_idx": 0
    }
  },
  "pc_list": ["0x4c36e6", "0x4c36e7", ...],
  "load_pcs": ["0x4c36f3", ...]
}
```

### assembly_context.jsonl
```json
{"pc": "0x4c36f3", "load_insn": "mov rax, QWORD PTR [rbp-0x10]",
 "function": "Perl_pp_add",
 "context_before": ["0x4c36e6: push rbp", ...],
 "context_after": ["0x4c36f7: add rax, 1", ...]}
```

### ground_truth.jsonl
```json
{"pc": "0x4c36f3", "best_prefetch": "ip_stride", "best_degree": 2,
 "best_amat": 12.5,
 "all_amats": {"no:1": 15.2, "next_line:1": 14.1, "ip_stride:1": 13.3, ...}}
```

### tuning_dataset.jsonl
```json
{"instruction": "Given the following x86-64 assembly context...",
 "label": "ip_stride:2",
 "pc": "0x4c36f3"}
```

## Configuration Reference

All configuration variables are in `config.sh`:

| Variable | Default | Description |
|----------|---------|-------------|
| `SPEC_ROOT` | `~/cpu2006` | SPEC CPU2006 installation |
| `PIN_ROOT` | `~/pin-3.22-...` | Intel PIN installation |
| `SIMPOINTS_TARBALL` | `~/Downloads/weights-and-simpoints-speccpu.tar.gz` | DPC-3 SimPoints |
| `INTERVAL_SIZE` | `100000000` | Instructions per SimPoint interval |
| `WEIGHT_THRESHOLD` | `0.01` | Min weight to generate trace |
| `CTX_BEFORE` | `8` | Assembly instructions before Load PC |
| `CTX_AFTER` | `4` | Assembly instructions after Load PC |
| `PREFETCH_POLICIES` | 5 policies × multiple degrees | Prefetch policies to evaluate |

## Key Design Decisions

1. **SimPoints are reused, binaries are local.** DPC-3 SimPoints are time-based
   (instruction count intervals), not address-based. The same interval covers the
   same program phase regardless of compilation differences.

2. **PC consistency within a binary.** Trace generation, profiling, and disassembly
   all operate on the same locally compiled binary, guaranteeing PC addresses match.

3. **One process per (trace, prefetcher, degree) combo.** Each profiling run is an
   independent ChampSim process that can be parallelized across machines.

4. **`train` input only.** SPEC `train` datasets are used for all profiling runs.
   `ref` is reserved for final end-to-end validation.

## Known Limitations

- Requires SPEC CPU2006 license for training data generation (SPEC2017/GAP/Splash
  needed for validation, not included).
- PIN tracer only works on x86-64 Linux.
- `objdump` parsing assumes GCC-style output format.
- Load PC detection in trace uses `source_memory[0] != 0` heuristic; some
  prefetch instructions may be classified as loads.
