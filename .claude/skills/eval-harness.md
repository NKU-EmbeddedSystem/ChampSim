---
name: eval-harness
description: Framework for running structured evaluations. Use when the user wants to create, run, or compare evaluations.
user-invocable: true
version: 2e671f8
---

# Eval Harness

When the user wants to run evaluations:

1. Place eval cases in `evals/` — each case is a self-contained script or config.
2. Document available evals in `evals/README.md`.
3. Results must be recorded in a structured, repeatable format.

## Directory structure

```
evals/
  README.md       # lists available evals and how to run them
  <eval-name>/    # one directory per eval case
```

## When creating a new eval

Create a directory under `evals/` with:
- A descriptive name matching what is being evaluated.
- A runnable script or config.
- Clear pass/fail criteria.
