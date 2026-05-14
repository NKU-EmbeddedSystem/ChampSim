---
name: docs-dual-format
description: Maintain project documentation in parallel markdown and HTML formats with shared style and navigation. Use when creating new docs, updating existing docs, or when the user asks about documentation standards.
user-invocable: true
version: 2e671f8
---

# Dual-Format Documentation

All project documentation in `docs/` must be maintained in two parallel formats:

| Format | Location | Purpose |
|--------|----------|---------|
| Markdown | `docs/md/` | CLI-friendly, version-control diffable |
| HTML | `docs/html/` | Browser-friendly, styled with shared CSS |

## Rules

1. **Content parity**: Every `.md` file in `docs/md/` must have a corresponding `.html` file in `docs/html/` with equivalent information.
2. **Shared style**: All HTML pages reference the same `style.css` from `docs/html/style.css`.
3. **Consistent navigation**: All HTML pages share the same `<nav>` with current-page highlighting. See Navigation rules below.
4. **README documents serving**: The project README must include instructions for starting the doc server and SSH tunnel.
5. **No placeholder text**: After completion, no `docs/md/*.md` file may contain template placeholder text (e.g., "补充…", "待定义", "模块 A"). Every claim must be derived from actual repo analysis.

### Navigation rules

When total documentation pages ≤ 6, use flat `<a>` links in the `<nav>`.

When total pages > 6, group links into 2-4 dropdown menus using the `nav-dropdown` pattern:

```html
<nav>
  <span class="brand">Project Name</span>
  <a href="index.html" class="active">总览</a>
  <div class="nav-dropdown">
    <span class="nav-dropdown-trigger active">开发文档</span>
    <div class="nav-dropdown-menu">
      <a href="architecture.html" class="active">架构</a>
      <a href="implementation.html">实现</a>
      ...
    </div>
  </div>
  ...
</nav>
```

Key rules for dropdowns:
- `<span class="nav-dropdown-trigger">` gets `class="active"` when any child is the current page
- The specific active child link also gets `class="active"` (shows a dot indicator via `::before`)
- Each dropdown menu has `z-index: 1000`; the nav itself has `z-index: 100` to prevent body content from occluding the menus
- The invisible bridge (`::after` pseudo-element, 12px tall) above each menu eliminates the hover gap between trigger and menu items
- Group pages by reader concern: development docs (architecture, implementation, schemas), operations (usage, deployment, ops), design records (ADRs, roadmap, interviews)

**When the nav changes** (page added/removed/renamed), every HTML file's `<nav>` must be updated identically. Only the `class="active"` positions differ per page.

## Page structure

### Minimum baseline (mandatory for every project)

These four pages must exist after initialization. They cover the essential dimensions of any project:

| Page | File | Covers |
|------|------|--------|
| Overview | `OVERVIEW.md` | Project purpose, core metrics, current status, quick nav |
| Architecture | `ARCHITECTURE.md` | Directory tree, module responsibilities, data flow, key schemas |
| Usage | `USAGE.md` | Build / run / test commands, configuration, environment setup |
| Design Decisions | `DESIGN_DECISIONS.md` | Key ADRs, why-not alternatives, tradeoffs made |

### Interactive Architecture Diagram (optional)

When the project has multiple modules spanning different languages or repos with clear data-flow phases (e.g., profiling → training → inference), the ARCHITECTURE page can include an interactive diagram with:

- **Phase buttons** — users click to switch between phases, each phase gets a distinct color (Phase 1: blue, Phase 2: purple, Phase 3: gold)
- **Canvas-animated flow lines** — dashed arrows with glowing dots that travel **sequentially step-by-step** (one step at a time, not simultaneous)
- **Step indicator panel** — DOM element showing current step label, progress bar, and per-phase colored badge, updated in sync with the animation

Use this when:
- The project has ≥2 independent modules or repos
- Data flows between them in discrete, nameable phases
- Each phase involves ≥2 steps of data handoff

Counter-constraint: do NOT use this for simple single-repo projects with trivial data flow. Use a static `flow-diagram` instead.

Template implementation:
- The `architecture.html` template contains the full Canvas animation engine (no modification needed) and placeholder data structures (`phaseSteps`, `highlightModules`, `phaseColors`) marked with `AGENT:` comments for the agent to fill from repo analysis
- All CSS classes are prefixed `arch-` and live in `style.css` under the "Interactive Architecture Diagram" comment block
- The animation engine is a state machine: `travel` (dot moves from source to target) → `pause` (completed connection held visible) → next step → cycle after all steps done
- In "全部连接" (phase 0) mode, all three phases' steps chain sequentially with their respective colors, showing the full end-to-end pipeline

### Adding pages beyond the baseline

The four core pages are a **floor, not a ceiling**. After analyzing the repo, add pages when the content warrants independent treatment. Use these heuristics to decide:

- **Independent subsystem or service** — if the repo contains multiple deployable units, each deserves its own architecture-style page
- **Non-trivial API contract or data schema** — if a reader would need to consult this regularly, give it a dedicated page
- **Multiple deployment environments** — if setup varies significantly across dev / staging / prod, split them
- **Contribution guide or testing strategy** — if these are substantial enough to be referenced independently

Counter-constraint: do NOT split for the sake of splitting, and do NOT cram unrelated topics into one giant page. The test: each page should be explainable to a new teammate as "this is the page about X."

When adding a page:
1. Create `docs/md/<SLUG>.md` with the content
2. Create `docs/html/<slug>.html` reusing the shared `<nav>` and CSS
3. Add the new page to the `<nav>` in every existing HTML page
4. Update the TOC in `docs/html/index.html`

#### Deep Interview page (optional)

When the project has recorded decision-making interviews (e.g., from OMC deep-interview sessions) or structured ADR discussions, a dedicated deep-interviews page can consolidate these into a top-down reader-friendly format.

Use the `deep-interviews.html` template with the `.di-*` CSS classes:

- `.di-layout` — flex container with sidebar + main content
- `.di-toc` — sticky sidebar table of contents (anchored per section)
- `.di-section` — each logical topic as a card
- `.di-q` / `.di-a` — Q&A pairs within each section (blue left-border for question, gold for answer/conclusion)

Content principles for this page:
- **Organize top-down, not chronologically.** Group by logical topic (concept → architecture → pipeline → evaluation), not by interview session or round number.
- **Answers are the developer's refined conclusions, not raw transcripts.** Paraphrase and restate. Keep the reasoning chain, discard conversational filler.
- **Each Q should represent a challenged assumption or a key fork in the road.** Not every interview round needs its own card — merge adjacent rounds that address the same theme.

Do NOT create this page if:
- The project has no interview/ADR records to consolidate
- All decisions are already adequately covered in DESIGN_DECISIONS.md
- The content would be a single section (one page should cover multiple themes)

## Workflow

This is a two-phase process. Phase 1 must complete before Phase 2 begins.

### Phase 1: Analyze the repo and fill docs/md/

Before writing any documentation, gather information from the actual repository:

1. **Read existing documentation sources** — `README.md`, `CLAUDE.md`, `AGENTS.md`, `.omc/` files, any existing `docs/` content
2. **Read manifest files** — `package.json`, `Cargo.toml`, `pyproject.toml`, `go.mod`, `Makefile`, or equivalent
3. **Map the directory tree** — identify top-level modules, their responsibilities, and how they connect
4. **Extract commands** — build, test, run, lint, deploy — from scripts, Makefile targets, CI configs, or manifest scripts
5. **Extract design rationale** — from `git log` for major architectural commits, ADR files, or CLAUDE.md context

Then produce or update `docs/md/`:

- Start with the four core files (OVERVIEW, ARCHITECTURE, USAGE, DESIGN_DECISIONS)
- Add supplementary `.md` files for any topic that meets the heuristics above
- Every file must contain concrete, repo-specific information — no placeholder text may survive

### Phase 2: Convert docs/md/ to docs/html/

For each `.md` file in `docs/md/`, generate or update the corresponding `.html` file in `docs/html/`:

1. Use the existing HTML pages as a style reference — same `<nav>`, same `<head>` structure, same CSS class vocabulary
2. Convert Markdown content to HTML, preserving headings, code blocks, tables, lists, and links
3. Ensure the `<nav>` in every HTML file lists all current pages with correct `class="active"` on the current page
4. Update `docs/html/index.html` to include the full table of contents

## Serving docs

```bash
python3 -m http.server 8080 -d docs/html/
```

SSH tunnel from local machine:
```bash
ssh -L 8080:127.0.0.1:8080 -N user@<server>
```

## Verification checklist

Before claiming completion, verify:

- [ ] Every `.md` file has a corresponding `.html` file
- [ ] No placeholder text remains in any `docs/md/*.md` file
- [ ] All HTML pages share the same `<nav>` with correct active-page highlighting
- [ ] All HTML pages reference `style.css`
- [ ] Cross-page links work (both in MD and HTML)
- [ ] `index.html` TOC lists every page
- [ ] README includes doc serving instructions
- [ ] If using dropdown nav: hovering from trigger to menu items is gap-free (no flicker/disappear); dropdown menus are not occluded by page content (body cards, pre blocks, etc.)
- [ ] If using `.di-*` deep-interview page: content is organized top-down by topic, not chronologically; answers are refined conclusions, not raw transcripts
