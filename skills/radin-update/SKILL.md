---
name: radin-update
description: Pull the latest version of radin's own repo and re-run install.sh to refresh agents/skills in ~/.claude/, overwriting what's there. Use when the user asks to "update radin", "pull the latest radin", "reinstall radin", or runs /radin-update.
---
# radin: Update

`install.sh` covers fresh interactive install only. Skill re-applies against
already-installed radin: pull latest commits in source clone, re-run
`install.sh` so `~/.claude/agents/` and `~/.claude/skills/` overwrite with
changes. Companion-tool installers in `install.sh` already skip-if-installed,
so re-run safe.

## Step 1: Locate source repo

Read `~/.claude/.radin/install_root` — `install.sh` writes resolved repo
path there each run. File missing (install predates skill): ask user for
path to radin clone instead of guessing.

## Step 2: Safety check

In that directory, confirm git repo, clean working tree:

```bash
cd "$(cat "$HOME/.claude/.radin/install_root")"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "not a git repo, stop"; exit 1; }
git status --porcelain
```

`git status --porcelain` prints anything: stop, report — don't pull over
uncommitted local changes.

## Step 3: Pull and preview

```bash
git pull
git log --oneline 'HEAD@{1}..HEAD'
```

Show user commit list before doing anything else, so they see what's about
to apply.

## Step 4: Confirm, then re-run install.sh

Ask explicit y/n confirmation before applying — overwrites files under
`~/.claude/agents/` and `~/.claude/skills/`. On yes, run:

```bash
./install.sh
```

from source repo directory. Companion-tool prompts (rtk, caveman,
code-review-graph) fire same as fresh install — expected, no-op if already
installed.

## Step 5: Report back

State: old commit → new commit, which `agents/*.md` / `skills/*/SKILL.md`
files changed in pulled range (`git diff --stat 'HEAD@{1}..HEAD'`), whether
any companion-tool prompt ran.

## Non-goals

- Don't update rtk/caveman/code-review-graph themselves — manage own updates
  via own tooling, this skill only refreshes radin's own agents/skills.
- Don't force pull through dirty working tree — stop, report instead.
- Don't touch per-project state under `~/.claude/.radin/projects/` —
  backlog/execution data, unrelated to updating radin's own code.