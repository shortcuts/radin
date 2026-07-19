---
name: radin-update
description: Pull the latest version of radin's own repo and re-run install.sh to refresh agents/skills in ~/.claude/, overwriting what's there. Use when the user asks to "update radin", "pull the latest radin", "reinstall radin", or runs /radin-update.
---

# radin: Update

`install.sh` only covers a fresh interactive install. This skill re-applies
it against an already-installed radin: pull the latest commits in the
source clone, then re-run `install.sh` so `~/.claude/agents/` and
`~/.claude/skills/` get overwritten with whatever changed. Companion-tool
installers in `install.sh` are already skip-if-installed, so re-running it
is safe.

## Step 1: Locate the source repo

Read `~/.claude/.radin/install_root` — `install.sh` writes the resolved
repo path there on every run. If the file is missing (install predates this
skill), ask the user for the path to their radin clone instead of guessing.

## Step 2: Safety check

In that directory, confirm it's a git repo with a clean working tree:

```bash
cd "$(cat "$HOME/.claude/.radin/install_root")"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "not a git repo, stop"; exit 1; }
git status --porcelain
```

If `git status --porcelain` prints anything, stop and report it — do not
pull over uncommitted local changes.

## Step 3: Pull and preview

```bash
git pull
git log --oneline 'HEAD@{1}..HEAD'
```

Show the user this commit list before doing anything else, so they see
what's about to be applied.

## Step 4: Confirm, then re-run install.sh

Ask for explicit y/n confirmation before applying — this overwrites files
under `~/.claude/agents/` and `~/.claude/skills/`. On yes, run:

```bash
./install.sh
```

from the source repo directory. Companion-tool prompts (rtk, caveman,
code-review-graph) will fire the same as a fresh install — that's expected,
they no-op if already installed.

## Step 5: Report back

State: old commit → new commit, which `agents/*.md` / `skills/*/SKILL.md`
files changed in the pulled range (`git diff --stat 'HEAD@{1}..HEAD'`), and
whether any companion-tool prompt ran.

## Non-goals

- Do not update rtk/caveman/code-review-graph themselves — they manage their
  own updates via their own tooling, this skill only refreshes radin's own
  agents/skills.
- Do not force a pull through a dirty working tree — stop and report instead.
- Do not touch per-project state under `~/.claude/.radin/projects/` — that's
  backlog/execution data, unrelated to updating radin's own code.
