# Technical Constraints

## Platform

- macOS and Linux. No Windows support planned.
- Arch-neutral via Homebrew: `/opt/homebrew`/`/usr/local` on macOS (ARM/Intel),
  `/home/linuxbrew/.linuxbrew` on Linux. No `uname -m` branching anywhere —
  resolution is delegated entirely to `brew`/`npm`/`cargo` via
  `$(command -v brew)` / `brew shellenv`, which picks the correct prefix for
  whichever machine is running the script.
- Where a command itself differs by OS rather than by package-manager prefix
  (e.g. BSD `md5` on macOS vs. GNU `md5sum` on Linux for the namespace-slug
  hash), branch on `command -v <tool>` — never on `uname`.

## Bash 3.2 compatibility

macOS ships `/bin/bash` 3.2 (Apple froze it pre-GPLv3) as the system bash.
Since the same scripts run unmodified on Linux (whose bash is typically
4+), the macOS floor is the binding constraint. All scripts in this repo
(`install.sh`, `sync.sh`, any future script) must stay bash-3.2-compatible:

- No associative arrays (`declare -A`)
- No `mapfile`
- No `${var,,}` / `${var^^}` case conversion

This is easy to violate by accident on a dev machine that has a newer bash on
`PATH` — always test against `/bin/bash` specifically, or at minimum grep for
these constructs before committing a script change.

## Companion-tool installs are advisory only

`install.sh` offers rtk, caveman, and code-review-graph via their own
existing install paths (brew/npm/cargo). It:

- Never vendors or forks their source.
- Never installs without an explicit `y` confirmation per tool.
- Never guarantees a companion tool's own install command succeeds — it asks
  and delegates, nothing more.

## `registry.json` tooling fallback

`jq` → `python3` → skip, in that order. The skip branch is a real path (stock
macOS may lack both), not an error condition — it must never block writing
`ISSUES_FILE` or creating the namespace directories.
