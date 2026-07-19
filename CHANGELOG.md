# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/), tied to
`.claude-plugin/plugin.json`'s `version` field.

## [Unreleased]

### Added
- Initial radin plugin scaffold: `radin-orchestrator`, `radin-plan`,
  `radin-review` agents/skills, synced from `~/.config/.claude`.
- `install.sh` — installs radin's agents/skills, offers companion tools
  (rtk, caveman, code-review-graph).
- `sync.sh` — pulls agent/skill edits from `~/.config/.claude` with a
  `diff -rq` drift gate.
- Canonical per-project storage namespace under `~/.claude/.radin/projects/<repo-slug>/`
  so no target repo receives radin-written files.
- `skills/thermo-nuclear/` shipped alongside `radin-review`.
- `skills/radin-setup-hooks/` — wires a companion tool's per-repo MCP/hook
  config (currently `code-review-graph`) into whatever repo it's invoked
  from, gated behind an explicit dry-run preview and y/n confirmation.
- `skills/radin-update/` — pulls the latest radin commits from the source
  clone (tracked via a new `~/.claude/.radin/install_root` marker file
  written by `install.sh`) and re-runs `install.sh` to refresh
  `~/.claude/agents/`/`~/.claude/skills/`.

### Changed
- `install.sh` now self-bootstraps: if run outside a real radin clone (e.g.
  piped via `curl | bash`), it clones the repo to `~/.claude/radin`
  (override with `RADIN_ROOT_OVERRIDE`) or `git pull`s an existing clone
  there, instead of requiring a manual `git clone` first. README's
  quickstart now leads with the one-liner.
- `skills/thermo-nuclear/` is now vendored verbatim from cursor/plugins'
  [`thermo-nuclear-code-quality-review`](https://github.com/cursor/plugins/blob/main/cursor-team-kit/skills/thermo-nuclear-code-quality-review/SKILL.md)
  instead of an unattributed local adaptation — credited in `README.md`.
- `sync.sh` is now gitignored — confirmed it's specific to the maintainer's
  personal `~/.config/.claude` fork path, not useful to other clones of
  this repo.

### Fixed
- `install.sh` installed `code-review-graph` via `npm install -g`, but it's
  a PyPI package, not npm — the install always failed silently. Now installs
  via `pipx`/`pip3 --user`.
- `caveman` npm install replaced with the correct Claude Code plugin
  marketplace flow (`claude plugin marketplace add` + `claude plugin
  install`).
- `install.sh` installed `rtk` via a nonexistent Homebrew tap
  (`rtk-ai/rtk/rtk`) — verified against rtk's real README and corrected to
  `brew install rtk`.
