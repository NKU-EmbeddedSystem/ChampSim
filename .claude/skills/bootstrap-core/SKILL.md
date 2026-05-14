---
name: bootstrap-core
description: Core project conventions — docs structure, schemas, artifacts layout, repo hygiene, and operational run patterns. Use when working on a bootstrapped project or when aligning an existing project to bootstrap conventions.
user-invocable: true
version: 2e671f8
---

# Bootstrap Core Conventions

This project follows agent-bootstrap conventions. All changes must respect these rules.

## Docs: Dual-Format Convention

All documentation lives in parallel markdown and HTML:

| Format | Location | Purpose |
|--------|----------|---------|
| Markdown | `docs/md/` | CLI-friendly, version-control diffable |
| HTML | `docs/html/` | Browser-friendly, shared `style.css` and nav |

**Rules:**
1. Every `.md` in `docs/md/` must have a corresponding `.html` in `docs/html/` with equivalent content.
2. All HTML pages share the same `<nav>` with current-page highlighting.
3. All HTML pages reference `docs/html/style.css`.
4. When creating new docs, write the `.md` first, then create the `.html` counterpart.

## Schemas

JSON schemas for structured state live in `schemas/`:
- `events.schema.json` — structured event format
- `traces_config.example.json` — trace configuration
- `phase_state.example.json` — phase state tracking
- `convergence_state.example.json` — convergence tracking

When designing state or event formats, create or update schemas here.

## Artifacts

Runtime outputs go under `artifacts/runs/<run-name>/`. Each run gets an isolated directory. Never write run artifacts directly into the project root.

## Repo Hygiene

Run the structure validator before committing major changes:
```bash
bash scripts/validate_repo_structure.sh
```

This checks that the directory layout matches the bootstrap convention.

## Operations

See `docs/md/OPERATIONS.md` for:
- How to start a run (standard entrypoint)
- Where logs and state are persisted
- Failure triage procedure

## State & Resume

The project supports stateful runs:
- Phase state tracks which phase is active and what's completed
- Convergence state tracks convergence criteria
- Configuration snapshots enable reproducible resumption
