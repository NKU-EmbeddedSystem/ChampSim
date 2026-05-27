---
name: multi-run
description: Run experiments with multiple configurations and compare results. Use when the user wants to run parameter sweeps, A/B comparisons, or batch experiments.
user-invocable: true
version: 2e671f8
---

# Multi-Run

When the user wants to run multiple experiment configurations and compare results:

1. Create a unique directory under `reports/` for each run (timestamp or descriptive label).
2. Save results in a structured format that enables cross-run comparison.
3. Produce a summary comparison when all runs complete.

## Directory structure

```
reports/
  <run-name>/   # one directory per experiment run
```

## When running comparisons

1. Name each run directory consistently (e.g. `baseline`, `lr-0.01`, `lr-0.001`).
2. Save key metrics in a parsable format (JSON, CSV) for easy comparison.
3. Write a brief comparison summary covering the key differences.
