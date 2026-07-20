# radin — Agent Reference

> Primary reference for AI coding agents. Read before touching any file in this repo.

---

## Project

| Field | Value |
|---|---|
| What it is | Claude Code plugin: agents + skills + install glue |
| Runtime language | None — bash only |
| Target OS | macOS and Linux |
| Supported architectures | Arch-neutral via Homebrew (works on both macOS's `/opt/homebrew`/`/usr/local` and Linuxbrew's `/home/linuxbrew/.linuxbrew`) — no `uname -m` branching, no OS branching beyond a `command -v` check where a tool differs (e.g. `md5` vs `md5sum`) |
| Distribution | Git repo ([github.com/shortcuts/radin](https://github.com/shortcuts/radin), currently private), installed via `curl \| bash install.sh` (self-clones to `~/.claude/radin`) or a manual `git clone` + `./install.sh` |

radin gives a solo dev on a small Claude subscription one install for a
cost-optimized agentic workflow: backlog-driven execution
(`radin-orchestrator`, `radin-plan`, `radin-review`) plus a curated
set of companion OSS tools (rtk, caveman, code-review-graph) installed —
never vendored or forked — via their own existing install paths.

## Dev loop

This repo is the **source of truth**. `agents/*.md` and `skills/*/SKILL.md`
are authored and edited directly here — no external fork, no sync step.

- Editing radin's own agents/skills: edit `agents/*.md` or
  `skills/*/SKILL.md` directly in this repo. (`thermo-nuclear` is not
  vendored here at all — `install.sh` downloads its `SKILL.md` straight from
  cursor/plugins at install time, same as any other companion tool. radin
  only vendors what it authored itself.)
- Editing `install.sh`, docs, or repo scaffolding: edit directly here as
  normal.
- `install.sh` installs from this repo into `~/.claude/agents` and
  `~/.claude/skills`, adding/updating what's there — one direction, repo to
  consumer.

## Storage contract

radin never writes a file into a consumer's target repo. All backlog content
and execution state lives in a canonical, per-project namespace:

```
~/.claude/.radin/
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

`<repo-slug>` is `$(basename "$REPO_ROOT")-$(printf '%s' "$REPO_ROOT" | md5 | cut -c1-8)`
(deterministic, collision-resistant, human-readable). Outside any git repo,
falls back to `no-repo-<cwd-hash>`. `registry.json` is a best-effort index —
atomic temp-file-plus-`mv` write, jq → python3 → skip fallback chain — never
required reading for core agent flows.

Every one of `agents/radin-orchestrator.md`, `agents/radin-plan.md`, and
`skills/radin-review/SKILL.md` resolves this namespace via an identical
shared block before doing anything else. Do not reintroduce a root-`ISSUES.md`
or `.shortcuts/*.json` assumption into any of these three files — that is the
exact problem this storage scheme replaces.

## Constraints

**Never touch anything in `~/.claude` (`~/.config/.claude`) besides what
radin itself added.** `~/.claude/agents` and `~/.claude/skills` are a shared
directory — the consumer's other agents/skills/tools live there too.
`install.sh` and `skills/radin-update` may only `cp`/`cp -r` radin's own
named files (`agents/*.md` that ship in this repo, radin's own
`skills/<name>/`) and `mkdir -p`. Never `rm`, never wildcard-delete a
directory, never overwrite a file radin didn't ship. Call this out
explicitly on any edit to `install.sh` or `skills/radin-update/SKILL.md`.

**macOS ships `/bin/bash` 3.2** (Apple froze it pre-GPLv3). Since scripts run
on both macOS and Linux, all scripts in this repo (`install.sh`,
any future script) must stay bash-3.2-compatible: no associative arrays, no
`mapfile`, no `${var,,}` case conversion. Call this out explicitly on any
script edit — easy to reach for bash 4+ syntax without noticing on a machine
that has a newer bash on `PATH`.

Arch/OS neutrality: no `uname -m` branching anywhere. Resolve via
`$(command -v brew)` / `brew shellenv`, letting brew/npm/cargo pick the
correct prefix for whichever machine (macOS ARM/Intel, or Linux via
Linuxbrew) is running the script. Where a command itself differs by OS (e.g.
BSD `md5` on macOS vs GNU `md5sum` on Linux), branch on `command -v <tool>`,
never on `uname`.

Companion-tool installs (`install.sh`) are advisory only — radin asks and
delegates, never guarantees rtk/caveman/code-review-graph's own install
succeeds, and never installs without an explicit `y` confirmation.

## Doc-maintenance policy

Work is not done until affected docs are updated in the same commit.

| File | Update when |
|---|---|
| `docs/architecture.md` | Storage scheme, namespace resolution, or plugin file layout changes |
| `docs/domain-models.md` | `registry.json` schema, `ISSUES.md` entry format, or plan-file format changes |
| `install.sh` companion-tool table (README) | A companion tool is added/removed/renamed |
| `CHANGELOG.md` | Any user-facing change, on every release |

## `ISSUES.md` at repo root

This is radin's **own** development backlog — a normal repo-root
`ISSUES.md`, same as any other project. This is intentionally the opposite of
what radin's shipped `radin-orchestrator` does for *consumers* (who get
`~/.claude/.radin/`-namespaced storage, never a repo-root file): radin's own
meta-development doesn't use its own shipped tooling by default, since that
tooling only activates once installed via `install.sh`. Not hypocrisy —
just radin not being self-hosted yet.

## Pre-commit checklist

- `bash -n install.sh` clean
- `shellcheck install.sh` clean (or documented exceptions only)
- Docs updated per the table above

## Code Style & Testing

→ See `CONTRIBUTING.md`

## Architecture

→ See `docs/architecture.md`

## Domain Models

→ See `docs/domain-models.md`

## Technical Constraints

→ See `docs/technical-constraints.md`
