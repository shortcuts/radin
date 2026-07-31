# radin — Agent Reference

> Read this before you touch any file in this repo.

---

## Project

| Field | Value |
| --- | --- |
| What it is | Claude Code plugin: agents + skills + install glue |
| Runtime language | None — bash only |
| Target OS | macOS and Linux |
| Supported architectures | Arch-neutral through Homebrew. Works on macOS's `/opt/homebrew`/`/usr/local` and on Linuxbrew's `/home/linuxbrew/.linuxbrew`. No `uname -m` branching. Branch on `command -v` only where a tool itself differs by OS (e.g. `md5` vs `md5sum`). |
| Distribution | Git repo ([github.com/shortcuts/radin](https://github.com/shortcuts/radin), currently private). Installed with `curl \| bash install.sh` — downloads the latest release tarball, or `main` if no release exists, into `~/.claude/radin`. No `git clone` needed. To hack on radin itself: `git clone` + `./install.sh`. |

radin gives a solo dev on a small Claude subscription one install for a
cost-optimized agentic workflow. It ships backlog-driven execution
(`radin-execute`, `radin-plan`, `radin-review`) and installs companion
tools (rtk, caveman, code-review-graph, thermo-nuclear, ponytail,
i-have-adhd) — some unconditionally, some only on explicit `y` confirmation.
radin never vendors or forks them.

## Dev loop

This repo is the source of truth. Edit `agents/*.md` and `skills/*/SKILL.md`
directly here — no external fork, no sync step.

- **Editing radin's own agents/skills:** edit `agents/*.md` or
  `skills/*/SKILL.md` directly. `thermo-nuclear` is the one exception — it
  isn't vendored here at all. `install.sh` downloads its `SKILL.md` straight
  from cursor/plugins at install time, the same as any other companion tool.
  radin only vendors what it wrote itself.
- **Editing `install.sh`, docs, or repo scaffolding:** edit directly, as
  normal.
- **`install.sh`** installs from this repo into `~/.claude/agents` and
  `~/.claude/skills`. It only adds or updates files there — one direction,
  repo to consumer.

## Storage contract

All backlog content and execution state live inside the target repo itself,
in one canonical directory at the repo root:

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

Outside any git repo, the current directory takes the repo root's place.
This directory is the only thing radin ever writes into a consumer's repo.
radin never edits the consumer's `.gitignore` — committing `.claude/.radin/`
(shared backlog) or ignoring it (private backlog) is the consumer's call.

Every one of `agents/radin-execute.md`, `skills/radin-plan/SKILL.md`,
`skills/radin-review/SKILL.md`, `skills/radin-record/SKILL.md`, and
`skills/radin-show/SKILL.md` goes through the shared backlog CLI
(`lib/radin-backlog.sh`) for namespace resolution and every deterministic
backlog operation (locate, append, remove, plan pointers) — the model
never hand-edits `index.jsonl` or a task file directly, and never
addresses backlog content by line number.
Do not reintroduce a monolithic `BACKLOG.md`, a
`~/.claude/.radin/projects/<slug>` namespace, or a `.shortcuts/*.json`
assumption into any of these files — those are the exact schemes this one
replaces.

## Backlog entry schema

`docs/schemas/backlog-entry.schema.json` is the formal, repo-internal contract
for the backlog's structure: `$BACKLOG_INDEX` (`index.jsonl`, one JSON
object per task) plus one file per task under `$BACKLOG_TASKS_DIR`. Each
index line carries `id` (a stable slug assigned at creation), `category`
(`feat`/`fix`/`chore`/`refactor` — the same vocabulary as a
conventional-commit type; there is no per-entry bracket tag beyond it),
`title`, and `file`. The matching task file holds the exhaustive
description, plus an optional trailing `**Plan:**` line.

Read the schema (and the matching section of `docs/domain-models.md`) before
adding a new category, or before writing a new skill/agent that writes to
the backlog. The schema is reference only — it never ships to consumers.
`lib/radin-backlog.sh` (which does ship) enforces the structural half (id
slugging/dedup, index-line shape, task-file location); each entry-writing
skill keeps only its body-content guidance inline in its own `SKILL.md`.

## Adding a new radin skill/agent

Skim an existing one first — `skills/radin-review/SKILL.md` is the shortest
complete example. The shared conventions below are easy to drift from if you
reinvent them from scratch.

1. **Namespace resolution and backlog I/O.** Go through
   `bash "$HOME/.claude/.radin/lib/radin-backlog.sh"` (see
   `docs/architecture.md`'s "Namespace resolution and the backlog CLI"
   section): `env` for `REPO_ROOT`/`NAMESPACE_DIR`/`BACKLOG_INDEX`/
   `BACKLOG_TASKS_DIR`, and `find`/`add`/`add-plan`/`remove` for entry
   operations. Don't re-embed path resolution or index/task-file surgery
   inline — the CLI is the single source of truth for both.
2. **Backlog writes.** If the new skill/agent appends entries, use the
   CLI's `add` and classify into an existing category
   (feat/fix/chore/refactor) — don't invent a fifth. If the shape genuinely
   needs to change, update `lib/radin-backlog.sh`,
   `docs/schemas/backlog-entry.schema.json`, and `docs/domain-models.md` in
   the same change.
3. **Docs.** Run the doc-maintenance checklist below. `docs/architecture.md`'s
   plugin repo layout and namespace-resolution sentence both need the new
   file's name added. README's "Tools you get" table needs a new row too —
   it drifts silently otherwise, since nothing else forces it to match
   `agents/`/`skills/`.
4. **`install.sh`.** New skills need a `cp -r` line, or `install.sh` never
   distributes them — a skill living only in `skills/` in this repo isn't
   installed anywhere yet. If the new skill/agent should be verified by
   `radin-doctor`, also add it to `lib/radin-doctor.sh`'s expected-file
   list — it isn't derived automatically from `install.sh`'s cp lines.

## Constraints

**Never touch anything in `~/.claude` (`~/.config/.claude`) besides what
radin itself added.** `~/.claude/agents` and `~/.claude/skills` are shared
directories — a consumer's other agents/skills/tools live there too.
`~/.claude/.radin/lib` is radin's own global tool directory (distinct from
the per-repo `<repo-root>/.claude/.radin/` backlog namespace — same `.radin`
name, different scope: this one holds shared scripts like
`radin-backlog.sh`, not backlog state). `install.sh` may only `cp`/`cp -r`
radin's own named files (`agents/*.md` that ship in this repo, radin's own
`skills/<name>/`, `lib/*` into `~/.claude/.radin/lib/`) and `mkdir -p`. Never
`rm`. Never wildcard-delete a directory. Never overwrite a file radin didn't
ship. Call this out explicitly on any edit to `install.sh`.

**macOS ships `/bin/bash` 3.2.** Apple froze it before the GPLv3 switch.
Since scripts run on both macOS and Linux, every script in this repo
(`install.sh`, any future script) must stay bash-3.2-compatible: no
associative arrays, no `mapfile`, no `${var,,}` case conversion. Call this
out explicitly on any script edit — it's easy to reach for bash-4+ syntax
without noticing on a machine that has a newer bash on `PATH`.

**Arch/OS neutrality.** No `uname -m` branching anywhere. Resolve through
`$(command -v brew)` / `brew shellenv` and let brew/npm/cargo pick the right
prefix for the machine (macOS ARM/Intel, or Linux via Linuxbrew). Where a
command itself differs by OS — e.g. BSD `md5` on macOS vs GNU `md5sum` on
Linux — branch on `command -v <tool>`, never on `uname`.

**Companion-tool installs are advisory only.** `install.sh` asks and
delegates; it never guarantees rtk/caveman/code-review-graph's own install
succeeds, and never installs without an explicit `y` confirmation.

**rtk is available for both user and sub-agent command execution.** When
installed, both sub-agents and users can wrap commands with `rtk` for
token-saving. Sub-agent prompts include guidance to use `rtk` when available
(`command -v rtk` succeeds); the fallback when absent is transparent.

## Doc-maintenance policy

A change isn't done until its affected docs are updated in the same commit.

| File | Update when |
| --- | --- |
| `docs/architecture.md` | Storage scheme, namespace resolution, or plugin file layout changes |
| `docs/domain-models.md` | Backlog entry format, plan-file format, or state-JSON schema changes |
| `install.sh` companion-tool table (README) | A companion tool is added, removed, or renamed |
| "Tools you get" table (README) | A radin-built skill/agent is added, removed, or renamed |
| `CHANGELOG.md` | Any user-facing change, on every release |

## Pre-commit checklist

- `make lint` clean (or documented exceptions only)
- `make test` clean
- Docs updated per the table above

## Code Style & Testing

→ See `CONTRIBUTING.md`

## Architecture

→ See `docs/architecture.md`

## Domain Models

→ See `docs/domain-models.md`

## Technical Constraints

→ See `docs/technical-constraints.md`
