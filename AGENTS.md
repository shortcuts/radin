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
(`radin-execute`, `radin-plan`, `radin-review`) and installs a curated
set of companion tools (rtk, caveman, code-review-graph) through their own
install paths. radin never vendors or forks them.

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

radin never writes a file into a consumer's target repo. All backlog content
and execution state live in one canonical, per-project namespace:

```
~/.claude/.radin/
  registry.json                     # repo-slug -> { path, updated_at }
  projects/
    <repo-slug>/
      BACKLOG.md                    # backlog, source of truth
      state/
        BACKLOG_STEPS.json          # radin-execute execution plan
      plans/
        <task-id>.md                # radin-plan output
      reviews/
        <review-name>.md            # radin-review / thermo-nuclear output
```

`<repo-slug>` is `$(basename "$REPO_ROOT")-$(printf '%s' "$REPO_ROOT" | md5 | cut -c1-8)`.
This is deterministic, collision-resistant, and still readable by a human.
Outside any git repo, it falls back to `no-repo-<cwd-hash>`. `registry.json`
is a best-effort index — an atomic temp-file-plus-`mv` write, with a
jq → python3 → skip fallback chain. No core agent flow depends on reading it.

Every one of `agents/radin-execute.md`, `skills/radin-plan/SKILL.md`,
`skills/radin-review/SKILL.md`, `skills/radin-record/SKILL.md`, and
`skills/radin-show/SKILL.md` resolves this namespace through an identical
shared block before doing anything else.
Do not reintroduce a root-`BACKLOG.md` or `.shortcuts/*.json` assumption into
any of these files — that is the exact problem this storage scheme replaces.

## `BACKLOG.md` entry schema

`docs/schemas/backlog-entry.schema.json` is the formal, repo-internal contract
for `$BACKLOG_FILE`'s structure. Entries live under top-level semver-style
category sections (`## feat`, `## fix`, `## chore`, `## refactor` — the same
vocabulary as a conventional-commit type, in that canonical order). Each
section holds `### title` entries with an exhaustive description underneath,
plus an optional trailing `**Plan:**` line. There is no per-entry bracket tag
— category is purely which section an entry lives under.

Read the schema (and the matching section of `docs/domain-models.md`) before
adding a new category, or before writing a new skill/agent that writes to
`BACKLOG.md`. The schema is reference only. It never ships to consumers, so
every entry-writing skill/agent must embed its concrete markdown format
inline in its own `SKILL.md`/agent file — a consumer's
`~/.claude/skills/radin-record/` never has this repo's `docs/` alongside it.

## Adding a new radin skill/agent

Skim an existing one first — `skills/radin-review/SKILL.md` is the shortest
complete example. The shared conventions below are easy to drift from if you
reinvent them from scratch.

1. **Namespace resolution.** Call
   `bash "$HOME/.claude/radin-lib/radin-namespace.sh"` (see
   `docs/architecture.md`'s "Namespace resolution" section) and read
   `REPO_ROOT`/`NAMESPACE_DIR`/`BACKLOG_FILE` from its output. Don't re-embed
   the resolution logic inline — `lib/radin-namespace.sh` is its single
   source of truth.
2. **`BACKLOG.md` writes.** If the new skill/agent appends entries, follow the
   schema above: classify into an existing category (feat/fix/chore/refactor)
   — don't invent a fifth. If the shape genuinely needs to change, update
   both `docs/schemas/backlog-entry.schema.json` and `docs/domain-models.md`
   in the same change.
3. **Docs.** Run the doc-maintenance checklist below. `docs/architecture.md`'s
   plugin repo layout and namespace-resolution sentence both need the new
   file's name added. README's "Tools you get" table needs a new row too —
   it drifts silently otherwise, since nothing else forces it to match
   `agents/`/`skills/`.
4. **`install.sh`.** New skills need a `cp -r` line, or `install.sh` never
   distributes them — a skill living only in `skills/` in this repo isn't
   installed anywhere yet.

## Constraints

**Never touch anything in `~/.claude` (`~/.config/.claude`) besides what
radin itself added.** `~/.claude/agents` and `~/.claude/skills` are shared
directories — a consumer's other agents/skills/tools live there too.
`install.sh` may only `cp`/`cp -r` radin's own named files (`agents/*.md`
that ship in this repo, radin's own `skills/<name>/`) and `mkdir -p`. Never
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

## Doc-maintenance policy

A change isn't done until its affected docs are updated in the same commit.

| File | Update when |
| --- | --- |
| `docs/architecture.md` | Storage scheme, namespace resolution, or plugin file layout changes |
| `docs/domain-models.md` | `registry.json` schema, `BACKLOG.md` entry format, or plan-file format changes |
| `install.sh` companion-tool table (README) | A companion tool is added, removed, or renamed |
| "Tools you get" table (README) | A radin-built skill/agent is added, removed, or renamed |
| `CHANGELOG.md` | Any user-facing change, on every release |

## `BACKLOG.md` at repo root

This is radin's own development backlog — a plain repo-root `BACKLOG.md`,
same as any other project. That's the opposite of what the shipped
`radin-execute` does for consumers, who get `~/.claude/.radin/`-namespaced
storage and never a repo-root file. radin's own development doesn't use its
own shipped tooling by default, because that tooling only activates once
installed through `install.sh`. This isn't hypocrisy — radin just isn't
self-hosted yet.

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
