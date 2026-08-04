# Technical Constraints

## Platform

- macOS + Linux only. No Windows support planned.
- Arch-neutral via Homebrew: `/opt/homebrew`/`/usr/local` on macOS
  (ARM/Intel), `/home/linuxbrew/.linuxbrew` on Linux. No `uname -m`
  branching anywhere — resolution goes through `brew`/`npm`/`cargo` via
  `$(command -v brew)` / `brew shellenv`, picks right prefix for
  machine running script.
- Command differs by OS, not just package-manager prefix
  (e.g. BSD `md5` on macOS vs GNU `md5sum` on Linux)? Branch on
  `command -v <tool>` — never `uname`.

## Bash 3.2 compatibility

macOS ships `/bin/bash` 3.2 as system bash (Apple froze it before GPLv3
switch). Same scripts run unmodified on Linux, where bash usually 4+, so
macOS's 3.2 binding floor. Every script here
(`install.sh`, future scripts) must stay bash-3.2-compatible:

- No associative arrays (`declare -A`)
- No `mapfile`
- No `${var,,}` / `${var^^}` case conversion

Easy to break by accident on dev machine w/ newer bash on
`PATH`. Test against `/bin/bash` directly, or grep for these
constructs before committing script change.

## Companion-tool installs are advisory only

`install.sh` offers rtk, caveman, code-review-graph through their own
existing install paths (brew/npm/cargo). It:

- Never vendors or forks their source.
- Never installs tool without explicit `y` confirmation per tool.
- Never guarantees companion tool's own install command succeeds — it
  asks and delegates, nothing more.
