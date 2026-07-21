# Changelog

Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Changed

- `radin-plan` now takes a single backlog entry as its scope instead of
  processing the whole backlog — point it at a task title/keyword. It uses
  `/ponytail` to judge (defaulting to no) whether that entry's scope should
  split into multiple independent sub-plans, confirms any split with the
  user, then writes one plan file and `**Plan:**` line per resulting
  sub-task. `radin-execute` now follows one or more `**Plan:**` lines per
  entry in order. `docs/schemas/backlog-entry.schema.json`'s `plan` field is
  now an array of lines instead of a single string.

### Added

- `skills/radin-record`: captures feedback, bugs, follow-ups, or ideas
  raised mid-session and logs them as structured `BACKLOG.md` entries.
- Renamed `ISSUES.md` to `BACKLOG.md` throughout (file name, `$BACKLOG_FILE`
  variable, `BACKLOG_STEPS.json`/`BACKLOG_PLAN_STEPS.json` state files,
  `docs/schemas/backlog-entry.schema.json`) — the backlog holds features and
  chores too, not only issues.
- `BACKLOG.md` now uses semver-style category sections (`feat`, `fix`,
  `chore`, `refactor` — the same vocabulary as a conventional-commit type)
  instead of ad-hoc per-entry tags. Applies to `radin-review`,
  `radin-record`, `radin-execute`, and `radin-plan`. Adds
  `docs/schemas/backlog-entry.schema.json` as the formal contract.
- `install.sh`: new optional prompt for
  [i-have-adhd](https://github.com/ayghri/i-have-adhd), installed the same
  way as `caveman` (Claude Code plugin marketplace).
- `install.sh`: new optional prompt for
  [ponytail](https://github.com/DietrichGebert/ponytail), same plugin
  marketplace flow.

### Fixed

- `install.sh`: declining a companion-tool prompt (`rtk`, `code-review-graph`,
  `caveman`) for a tool not already installed silently killed the rest of
  the script under `set -e`. A bare `return` after a failed `[ ]` test
  propagated that test's nonzero exit status. `install_if_confirmed` and
  `install_plugin_if_confirmed` now `return 0` explicitly on decline.
- CI (`.github/workflows/ci.yml`) referenced a `sync.sh` that doesn't exist
  in this repo. Removed the dead `bash -n`/`shellcheck`/drift-gate steps that
  depended on it.

### Added

- `tests/install.bats`: BATS suite for `install.sh` — source resolution from
  a real checkout, agent/skill installation, `.radin` namespace/registry
  idempotency, companion-tool prompt gating, and the missing-Homebrew
  failure path. Runs in CI via a new `test` job.

## [0.1.0] — 2026 (unreleased on GitHub)

Initial scaffold: `radin-execute` and `radin-plan` agents,
`radin-review` skill, the `~/.claude/.radin/` storage namespace, and
`install.sh` with optional companion-tool installs (rtk, caveman,
code-review-graph).
