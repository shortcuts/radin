# Changelog

Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- `skills/radin-record`: new skill to capture feedback, bugs, follow-ups, or
  ideas raised mid-session and log them as structured `ISSUES.md` entries.
- `ISSUES.md` restructured around semver-style category sections (`feat`,
  `fix`, `chore`, `refactor`, same vocabulary as a conventional-commit type)
  instead of ad-hoc per-entry tags — applies across `radin-review`,
  `radin-record`, `radin-orchestrator`, and `radin-plan`. Introduces
  `docs/schemas/issues-entry.schema.json` as the formal contract for this
  structure.
- `install.sh`: new optional companion-tool prompt for
  [i-have-adhd](https://github.com/ayghri/i-have-adhd) — installs the same
  way as `caveman` (Claude Code plugin marketplace flow).

### Fixed

- `install.sh`: declining a companion-tool prompt (`rtk`, `code-review-graph`,
  `caveman`) for a tool not already installed silently killed the rest of the
  script under `set -e` — a bare `return` after a failed `[ ]` test
  propagated that test's nonzero exit status. Both `install_if_confirmed` and
  `install_plugin_if_confirmed` now `return 0` explicitly on decline.
- CI (`.github/workflows/ci.yml`) referenced a `sync.sh` that doesn't exist in
  this repo — removed the dead `bash -n`/`shellcheck`/drift-gate steps that
  depended on it.

### Added

- `tests/install.bats`: BATS suite covering `install.sh` — source resolution
  from a real checkout, agent/skill installation, `.radin` namespace/registry
  idempotency, companion-tool prompt gating, and the missing-Homebrew failure
  path. Runs in CI via a new `test` job.

## [0.1.0] — 2026 (unreleased on GitHub)

Initial scaffold: `radin-orchestrator` and `radin-plan` agents, `radin-review`
skill, `~/.claude/.radin/` storage namespace, `install.sh` with optional
companion-tool installs (rtk, caveman, code-review-graph).
