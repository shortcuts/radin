# Architecture

## What radin is

A Claude Code plugin — agents, skills, and install glue — distributed as a
git repo and installed with `install.sh`. No runtime language, bash only,
macOS and Linux (through Homebrew/Linuxbrew — see `AGENTS.md`'s
arch-neutrality rule).

## Storage model

All radin state — backlog content and execution state — lives outside any
target repo, in a per-project namespace under `~/.claude/.radin/`:

```
~/.claude/.radin/
  registry.json                     # repo-slug -> { path, updated_at }
  projects/
    <repo-slug>/
      BACKLOG.md                    # backlog, source of truth
      state/
        BACKLOG_STEPS.json          # radin-execute execution plan
        BACKLOG_PLAN_STEPS.json     # radin-plan sub-task list for one scoped task
      plans/
        <task-id>.md                # radin-plan output, one file per plan
      reviews/
        <review-name>.md            # radin-review / thermo-nuclear output
```

No target repo ever receives a file written by radin. This replaced an
earlier, ambiguous scheme: `BACKLOG.md` could live at a repo root or at
`~/.claude/BACKLOG.md`, and per-repo state lived in `.shortcuts/*.json`. Both
collided across repos worked on with the same Claude install, and neither
was fit to open-source — a stranger's repo shouldn't get an opinionated file
dropped at its root.

## Namespace resolution

Every one of `agents/radin-execute.md`, `agents/radin-plan.md`,
`skills/radin-review/SKILL.md`, and `skills/radin-record/SKILL.md` resolves
the namespace by running the same shared script —
`lib/radin-namespace.sh`, the single source of truth for this logic —
before doing anything else:

```bash
bash "$HOME/.claude/radin-lib/radin-namespace.sh"
```

`install.sh` copies `lib/radin-namespace.sh` to `~/.claude/radin-lib/`. A
consumer install never has this repo's `lib/` directly, so the script has to
be distributed like any other radin file. It prints `REPO_ROOT`,
`NAMESPACE_DIR`, and `BACKLOG_FILE` to stdout; the calling agent/skill reads
those values from the printed output for the rest of its session.

Inside the script:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
if command -v md5 >/dev/null 2>&1; then
  HASH_CMD="md5"
else
  HASH_CMD="md5sum"
fi
if [ -n "$REPO_ROOT" ]; then
  SLUG="$(basename "$REPO_ROOT")-$(printf '%s' "$REPO_ROOT" | $HASH_CMD | cut -c1-8)"
else
  SLUG="no-repo-$(printf '%s' "$PWD" | $HASH_CMD | cut -c1-8)"
fi
NAMESPACE_DIR="$HOME/.claude/.radin/projects/$SLUG"
```

`basename` keeps the directory readable in `ls ~/.claude/.radin/projects/`.
The hash suffix disambiguates two repos that share a basename on disk. `md5`
is BSD/macOS-native; Linux ships GNU coreutils' `md5sum` instead, so the
block branches on `command -v md5` rather than assuming either one. Outside
any git repo, the slug falls back to `no-repo-<cwd-hash>`.

`registry.json` is a best-effort index (repo-slug → path/updated_at), useful
for a future `radin list`/`radin status` command. No core agent flow depends
on reading it — a skipped upsert (no `jq`/`python3` on the machine) never
blocks `BACKLOG_FILE` from being written correctly. Writes are atomic: a
same-directory temp file (`$REGISTRY.tmp.$$`) is written and then `mv`'d
into place.

`agents/radin-execute.md` and `agents/radin-plan.md` also share a
second file — `lib/radin-prioritization.md` — the single source of truth
for backlog parsing rules, task priority criteria, and the state-file JSON
schema. Both agents read it via `$HOME/.claude/radin-lib/radin-prioritization.md`
at the start of Phase 1, instead of embedding their own copy.
`radin-execute` uses all of it, to prioritize and order the whole backlog.
`radin-plan` only uses the parsing and state-schema sections — it's scoped
to a single task the user points it at, not the whole backlog, so it has
nothing to prioritize. The two agents diverge after that point:
`radin-execute` executes each task; `radin-plan` judges whether its one
scoped task should split into independent sub-plans (confirming with the
user before splitting), then writes a plan file and `**Plan:**` pointer per
resulting sub-task.

To update radin itself, re-run `install.sh` — plain `curl | bash`, or
`./install.sh` from a dev clone. It always re-downloads or re-copies
`agents/*.md` and `skills/*/`, overwriting what's in `~/.claude/`. Pass
`--force` to also re-prompt on companion tools `install.sh` would otherwise
skip because they're already on the system.

## Plugin repo layout

```
radin/
  .claude-plugin/
    plugin.json
  agents/
    radin-execute.md
    radin-plan.md
  skills/
    radin-review/
      SKILL.md
    radin-record/
      SKILL.md
    radin-setup-hooks/
      SKILL.md
    radin-stats/
      SKILL.md
  docs/
  lib/
    radin-namespace.sh
    radin-prioritization.md
  install.sh
  README.md
```

## Authoring vs. distribution

This repo is the source of truth. `agents/*.md` and `skills/*/SKILL.md` are
authored and edited directly here — no external fork, no sync step.
`install.sh` distributes them one-directionally into `~/.claude/agents` and
`~/.claude/skills`. `thermo-nuclear` isn't part of this repo at all:
`install.sh` downloads its `SKILL.md` straight from cursor/plugins at
install time.
