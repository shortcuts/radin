# radin — Agent Reference

> Read this before touch any file in repo.

---

## Project

| Field | Value |
| --- | --- |
| What it is | Claude Code plugin: agents + skills + install glue |
| Runtime language | None — bash only |
| Target OS | macOS and Linux |
| Supported architectures | Arch-neutral through Homebrew. Works on macOS's `/opt/homebrew`/`/usr/local` and on Linuxbrew's `/home/linuxbrew/.linuxbrew`. No `uname -m` branching. Branch on `command -v` only where tool itself differs by OS (e.g. `md5` vs `md5sum`). |
| Distribution | Git repo ([github.com/shortcuts/radin](https://github.com/shortcuts/radin), currently private). Install with `curl \| bash install.sh` — downloads latest release tarball, or `main` if no release exists, into `~/.claude/radin`. No `git clone` needed. Hack on radin itself: `git clone` + `./install.sh`. |

radin gives solo dev on small Claude subscription one install for cost-optimized agentic workflow. Ships backlog-driven execution
(`radin-execute`, `radin-plan`, `radin-review`), installs companion
tools (rtk, caveman, code-review-graph, thermo-nuclear, ponytail) —
some unconditional, some only on explicit `y` confirm.
radin never vendors or forks them.

## Dev loop

This repo source of truth. Edit `agents/*.md` and `skills/*/SKILL.md`
directly here — no external fork, no sync step.

- **Editing radin's own agents/skills:** edit `agents/*.md` or
  `skills/*/SKILL.md` directly. `thermo-nuclear` one exception — not
  vendored here at all. `install.sh` downloads its `SKILL.md` straight
  from cursor/plugins at install time, same as any other companion tool.
  radin only vendors what it wrote itself.
- **Editing `install.sh`, docs, or repo scaffolding:** edit directly, as
  normal.
- **`install.sh`** installs from this repo into `~/.claude/agents` and
  `~/.claude/skills`. Only adds or updates files there — one direction,
  repo to consumer.

## Storage contract

All backlog content and execution state live inside target repo itself,
in one canonical directory at repo root:

```
<repo-root>/.claude/.radin/
  backlog/
    index.jsonl                  # backlog index, source of truth: one JSON object per task
    tasks/
      <task-id>.md                # one file per task: description + any **Plan:** lines
  state/
    BACKLOG_STEPS.json          # radin-execute execution plan
    completed.json               # radin-execute completed-task -> commit log
  plans/
    <task-id>.md                # radin-plan output
  reviews/
    <review-name>.md            # radin-review / thermo-nuclear output
```

Outside any git repo, current directory takes repo root's place.
This directory only thing radin ever writes into consumer's repo.
radin never edits consumer's `.gitignore` — committing `.claude/.radin/`
(shared backlog) or ignoring it (private backlog) is consumer's call.

Every one of `agents/radin-execute.md`, `skills/radin-plan/SKILL.md`,
`skills/radin-review/SKILL.md`, `skills/radin-record/SKILL.md`, and
`skills/radin-show/SKILL.md` goes through shared backlog CLI
(`lib/radin-backlog.sh`) for namespace resolution and every deterministic
backlog operation (locate, append, remove, plan pointers) — model
never hand-edits `index.jsonl` or task file directly, never
addresses backlog content by line number.
Don't reintroduce monolithic `BACKLOG.md`, a
`~/.claude/.radin/projects/<slug>` namespace, or `.shortcuts/*.json`
assumption into any of these files — those exact schemes this one
replaces.

## Backlog entry schema

`docs/schemas/backlog-entry.schema.json` formal, repo-internal contract
for backlog's structure: `$BACKLOG_INDEX` (`index.jsonl`, one JSON
object per task) plus one file per task under `$BACKLOG_TASKS_DIR`. Each
index line carries `id` (stable slug assigned at creation), `category`
(`feat`/`fix`/`chore`/`refactor` — same vocabulary as
conventional-commit type; no per-entry bracket tag beyond it),
`title`, `file`. Matching task file holds exhaustive
description, plus optional trailing `**Plan:**` line.

Read schema (and matching section of `docs/domain-models.md`) before
adding new category, or before writing new skill/agent that writes to
backlog. Schema reference only — never ships to consumers.
`lib/radin-backlog.sh` (which does ship) enforces structural half (id
slugging/dedup, index-line shape, task-file location); each entry-writing
skill keeps only its body-content guidance inline in own `SKILL.md`.

## Adding new radin skill/agent

Skim existing one first — `skills/radin-review/SKILL.md` shortest
complete example. Shared conventions below easy to drift from if you
reinvent from scratch.

1. **Namespace resolution and backlog I/O.** Go through
   `bash "$HOME/.claude/.radin/lib/radin-backlog.sh"` (see
   `docs/architecture.md`'s "Namespace resolution and backlog CLI"
   section): `env` for `REPO_ROOT`/`NAMESPACE_DIR`/`BACKLOG_INDEX`/
   `BACKLOG_TASKS_DIR`, and `find`/`add`/`add-plan`/`remove` for entry
   operations. Don't re-embed path resolution or index/task-file surgery
   inline — CLI single source of truth for both.
2. **Backlog writes.** If new skill/agent appends entries, use CLI's
   `add` and classify into existing category
   (feat/fix/chore/refactor) — don't invent fifth. If shape genuinely
   needs to change, update `lib/radin-backlog.sh`,
   `docs/schemas/backlog-entry.schema.json`, and `docs/domain-models.md` in
   same change.
3. **Docs.** Run doc-maintenance checklist below. `docs/architecture.md`'s
   plugin repo layout and namespace-resolution sentence both need new
   file's name added. README's "Tools you get" table needs new row too —
   drifts silently otherwise, since nothing else forces match to
   `agents/`/`skills/`.
4. **`install.sh`.** New skills need `cp -r` line, or `install.sh` never
   distributes them — skill living only in `skills/` in this repo isn't
   installed anywhere yet. If new skill/agent should be verified by
   `radin-doctor`, also add to `lib/radin-doctor.sh`'s expected-file
   list — not derived automatically from `install.sh`'s cp lines.

## Constraints

**Never touch anything in `~/.claude` (`~/.config/.claude`) besides what
radin itself added.** `~/.claude/agents` and `~/.claude/skills` shared
directories — consumer's other agents/skills/tools live there too.
`~/.claude/.radin/lib` radin's own global tool directory (distinct from
per-repo `<repo-root>/.claude/.radin/` backlog namespace — same `.radin`
name, different scope: this one holds shared scripts like
`radin-backlog.sh`, not backlog state). `install.sh` may only `cp`/`cp -r`
radin's own named files (`agents/*.md` that ship in this repo, radin's own
`skills/<name>/`, `lib/*` into `~/.claude/.radin/lib/`) and `mkdir -p`. Never
`rm`. Never wildcard-delete directory. Never overwrite file radin didn't
ship. Call out explicitly on any edit to `install.sh`.

**macOS ships `/bin/bash` 3.2.** Apple froze it before GPLv3 switch.
Since scripts run on both macOS and Linux, every script in this repo
(`install.sh`, any future script) must stay bash-3.2-compatible: no
associative arrays, no `mapfile`, no `${var,,}` case conversion. Call
out explicitly on any script edit — easy to reach for bash-4+ syntax
without noticing on machine with newer bash on `PATH`.

**Arch/OS neutrality.** No `uname -m` branching anywhere. Resolve through
`$(command -v brew)` / `brew shellenv` and let brew/npm/cargo pick right
prefix for machine (macOS ARM/Intel, or Linux via Linuxbrew). Where
command itself differs by OS — e.g. BSD `md5` on macOS vs GNU `md5sum` on
Linux — branch on `command -v <tool>`, never on `uname`.

**Companion-tool installs advisory only.** `install.sh` asks and
delegates; never guarantees rtk/caveman/code-review-graph's own install
succeeds, never installs without explicit `y` confirm.

**rtk available for both user and sub-agent command execution.** When
installed, both sub-agents and users can wrap commands with `rtk` for
token-saving. Sub-agent prompts include guidance to use `rtk` when available
(`command -v rtk` succeeds); fallback when absent transparent.

## Doc-maintenance policy

Change isn't done until affected docs updated in same commit.

| File | Update when |
| --- | --- |
| `docs/architecture.md` | Storage scheme, namespace resolution, or plugin file layout changes |
| `docs/domain-models.md` | Backlog entry format, plan-file format, or state-JSON schema changes |
| `install.sh` companion-tool table (README) | Companion tool added, removed, or renamed |
| "Tools you get" table (README) | radin-built skill/agent added, removed, or renamed |
| `CHANGELOG.md` | Any user-facing change, on every release |

## Pre-commit checklist

- `make lint` clean (or documented exceptions only)
- `make test` clean
- Docs updated per table above

## Code Style & Testing

→ See `CONTRIBUTING.md`

## Architecture

→ See `docs/architecture.md`

## Domain Models

→ See `docs/domain-models.md`

## Technical Constraints

→ See `docs/technical-constraints.md`
