# Architecture

## What radin is

A Claude Code plugin (agents + skills + install glue), distributed as a git
repo and installed via `install.sh`. No runtime language — bash only,
macOS and Linux (via Homebrew/Linuxbrew — see `AGENTS.md`'s arch-neutrality
rule).

## Storage model

All radin state — backlog content and execution state — lives outside any
target repo, in a per-project namespace under `~/.claude/.radin/`:

```
~/.claude/.radin/
  install_root                      # path to the radin source clone, written by install.sh
  registry.json                     # repo-slug -> { path, updated_at }
  projects/
    <repo-slug>/
      ISSUES.md                     # backlog, source of truth
      state/
        ISSUES_STEPS.json           # radin-orchestrator execution plan
        ISSUES_PLAN_STEPS.json      # radin-plan execution plan
      plans/
        <task-id>.md                # radin-plan output
      reviews/
        <review-name>.md            # radin-review / thermo-nuclear output
```

No target repo ever receives a file written by radin. This replaced an
earlier ambiguous scheme where `ISSUES.md` could live at a repo root or in
`~/.claude/ISSUES.md`, and per-repo `.shortcuts/*.json` state files —
both of which collided across multiple repos worked on with the same Claude
install, and were unsuitable for open-sourcing (a stranger's repo shouldn't
get an opinionated file dropped at its root).

## Namespace resolution

Every one of `agents/radin-orchestrator.md`, `agents/radin-plan.md`, and
`skills/radin-review/SKILL.md` resolves the namespace via an identical
shared block before doing anything else:

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

`basename` keeps the directory human-readable in `ls ~/.claude/.radin/projects/`;
the hash suffix disambiguates two repos sharing a basename on disk. `md5` is
BSD/macOS-native; Linux ships GNU coreutils' `md5sum` instead, so the block
branches on `command -v md5` rather than assuming one or the other. Outside
any git repo, the slug falls back to `no-repo-<cwd-hash>`.

`registry.json` is a best-effort index (repo-slug → path/updated_at), useful
for a future `radin list`/`radin status` command. It is never required
reading for core agent flows — a skipped upsert (no `jq`/`python3` on the
machine) never blocks `ISSUES_FILE` from being written correctly. Writes are
atomic: a same-directory temp file (`$REGISTRY.tmp.$$`) is written and then
`mv`'d into place.

`install_root` is a plain-text file holding the absolute path to the radin
source clone `install.sh` was run from — written unconditionally on every
`install.sh` run. `skills/radin-update/SKILL.md` reads it to find the repo
to `git pull` and re-install from, without hardcoding a hosting URL.

## Plugin repo layout

```
radin/
  .claude-plugin/
    plugin.json
  agents/
    radin-orchestrator.md
    radin-plan.md
  skills/
    radin-review/
      SKILL.md
    radin-setup-hooks/
      SKILL.md
    radin-update/
      SKILL.md
  docs/
  install.sh
  README.md
```

## Authoring vs. distribution

This repo is the source of truth. `agents/*.md` and `skills/*/SKILL.md` are
authored and edited directly here — no external fork, no sync step.
`install.sh` distributes them one-directionally into `~/.claude/agents` and
`~/.claude/skills`. `thermo-nuclear` is not part of this repo at all:
`install.sh` downloads its `SKILL.md` straight from cursor/plugins at install
time.
