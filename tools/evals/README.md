# Evals

End-to-end evaluation cases for the profiling pipeline.
Each subdirectory is a self-contained eval case with clear pass/fail criteria.

## Available evals

| Eval | Description | Command |
|------|-------------|---------|
| `pc_match` | Verify that trace PCs match objdump disassembly for a benchmark | `bash evals/pc_match/run.sh 400.perlbench` |
| `batch_profile` | Run full profiling pipeline on all benchmarks with all prefetchers | `bash evals/batch_profile/run.sh` |

## Pass/Fail criteria

### pc_match
- **PASS**: ≥ 90% of unique Load PCs from the trace are found in the disassembly index.
- **FAIL**: < 90% match rate.

### batch_profile
- **PASS**: All benchmarks complete Stage 1-4 without error. All profiling outputs contain ≥ 1 PC record.
- **FAIL**: Any benchmark fails or produces empty profiling output.

## Adding a new eval

1. Create `evals/<name>/` with `run.sh` and any config files.
2. `run.sh` must exit 0 on pass, non-zero on fail.
3. Add an entry to this README.
