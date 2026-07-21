# Technical Constraints

## Platform

- macOS and Linux only. No Windows support planned.
- Arch-neutral through Homebrew: `/opt/homebrew`/`/usr/local` on macOS
  (ARM/Intel), `/home/linuxbrew/.linuxbrew` on Linux. No `uname -m`
  branching anywhere — resolution goes through `brew`/`npm`/`cargo` via
  `$(command -v brew)` / `brew shellenv`, which picks the right prefix for
  the machine running the script.
- Where a command itself differs by OS, not just by package-manager prefix
  (e.g. BSD `md5` on macOS vs GNU `md5sum` on Linux, for the namespace-slug
  hash), branch on `command -v <tool>` — never on `uname`.

## Bash 3.2 compatibility

macOS ships `/bin/bash` 3.2 as its system bash (Apple froze it before the
GPLv3 switch). The same scripts run unmodified on Linux, where bash is
usually 4+, so macOS's 3.2 is the binding floor. Every script in this repo
(`install.sh`, any future script) must stay bash-3.2-compatible:

- No associative arrays (`declare -A`)
- No `mapfile`
- No `${var,,}` / `${var^^}` case conversion

This is easy to break by accident on a dev machine with a newer bash on
`PATH`. Test against `/bin/bash` directly, or at minimum grep for these
constructs before committing a script change.

## Companion-tool installs are advisory only

`install.sh` offers rtk, caveman, and code-review-graph through their own
existing install paths (brew/npm/cargo). It:

- Never vendors or forks their source.
- Never installs a tool without an explicit `y` confirmation per tool.
- Never guarantees a companion tool's own install command succeeds — it
  asks and delegates, nothing more.

## `registry.json` tooling fallback

`jq` → `python3` → skip, in that order. The skip branch is a real path
(stock macOS may lack both), not an error condition. It must never block
writing `BACKLOG_FILE` or creating the namespace directories.
