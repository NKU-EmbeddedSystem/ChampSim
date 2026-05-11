# Reports

Structured experiment results following the multi-run convention.
Each run produces a timestamped directory with logs and metrics.

## Directory layout

```
reports/
  batch-20260512-143022/      # one run
    summary.txt               # run metadata
    completed.txt             # benchmark completion log
    failures.txt              # failure log (empty = all passed)
    400.perlbench.log         # per-benchmark full log
    429.mcf.log
    ...
  batch-20260512-160015/      # another run
    ...
```

## Running comparisons

```bash
# Compare profiling output sizes across runs
for d in reports/batch-*/; do
    echo "$(basename $d): $(ls $d/*.log 2>/dev/null | wc -l) benchmarks"
done
```

## Convention

- Directory name: `batch-YYYYMMDD-HHMMSS`
- Per-benchmark logs: `<benchmark>.log`
- Summary: `summary.txt` — run parameters and result
- Completed: `completed.txt` — benchmarks that finished successfully
- Failures: `failures.txt` — benchmarks that failed with error details
