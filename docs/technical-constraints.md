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

## Sub-agents cannot reach the user, and cannot be notified

`radin-execute` always runs as sub-agent, and dispatches sub-agents of its own.
Two limits follow, and both show up as hang -- run stops mid-task, task claimed
`in_progress`, nothing committed:

- **No prose channel.** Anything sub-agent writes goes to calling session, never
  to user. Only `AskUserQuestion` is harness-mediated. So no radin agent or
  prompt may send sub-agent into skill that asks in prose and waits for answer
  (`/grilling`) -- skill ends its turn, orchestrator sees report with no
  `STATUS:` line.
- **No notification.** Turn-based sub-agent cannot receive background-task
  completion. So every `Task` call runs `run_in_background: false`, and no
  prompt may route sub-agent into skill that spawns background agent
  (`/research`). Same rule applies inside parallel mode: several sub-agents in
  one message, still none in background.

Consequence for both: when radin needs fact, it dispatches own synchronous
read-only sub-agent (Fact-finding prompt in `lib/radin-execute-prompts.md`) --
never third-party research skill. When radin needs decision, it asks through
`AskUserQuestion`, or records entry `blocked` and moves on.

`**Skill:**` pointers user recorded pass through to execution sub-agent
unfiltered except for this one class. Filtering happens at forward point in
`agents/radin-execute.md` Step 4b, and dropped skill named in Phase 5 summary
so user can run it themselves.
