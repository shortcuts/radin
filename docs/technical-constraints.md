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
- Never installs tool without explicit pick of yes option per tool.
- Every install prompt arrow-key picker on interactive terminal, numbered
  prompt otherwise. Unreadable answer takes default, never a silent yes.
- Never guarantees companion tool's own install command succeeds — it
  asks and delegates, nothing more.

## Sub-agents cannot reach the user, and cannot be notified

Every radin entry point is skill, so it runs in user's own thread and can
talk to them. Sub-agents it dispatches cannot. Three limits apply to those
sub-agents, and all show up as hang -- run stops mid-task, task claimed
`in_progress`, nothing committed:

- **No prose channel.** Anything sub-agent writes goes to calling session,
  never to user. So no radin prompt may send sub-agent into skill that asks in
  prose and waits for answer (`/grilling`) -- skill ends its turn, router sees
  report with no `STATUS:` line.
- **No `AskUserQuestion`.** Claude Code removes it from every sub-agent,
  foreground and background alike, even when `tools` lists it. Sub-agent has no
  way to ask anything at all. This is why radin-execute is skill rather than
  agent: its Phase 2 gate must ask, so as agent it could never satisfy own
  gate.
- **No notification.** Turn-based sub-agent cannot receive background-task
  completion. So every `Task` call runs `run_in_background: false`, and no
  prompt may route sub-agent into skill that spawns background agent
  (`/research`). Workflows same class: `Workflow` tool, `/deep-research`, and
  any saved workflow command (`.claude/workflows/`, `~/.claude/workflows/`)
  always run in background — never from radin skill's sub-agent. Same rule
  applies inside parallel mode: several sub-agents in one message, still none
  in background.

Consequence: when radin needs fact, it dispatches own synchronous read-only
sub-agent (Fact-finding prompt in `lib/radin-execute-prompts.md`) -- never
third-party research skill. When radin needs decision, router asks user
directly, or records entry `blocked` and moves on.

`**Skill:**` pointers user recorded pass through to execution sub-agent
unfiltered except for this one class. Filtering happens at forward point in
`skills/radin-execute/SKILL.md` Step 4b, and dropped skill named in Phase 5
summary so user can run it themselves.

## Background sub-agents get no `Agent` tool

Background sub-agent keeps every MCP tool but only these built-ins: `Read`,
`Grep`, `Glob`, `Bash`, `PowerShell`, `Edit`, `Write`, `NotebookEdit`,
`WebFetch`, `WebSearch`, `TodoWrite`, `Skill`, `ToolSearch`, `EnterWorktree`,
`ExitWorktree`, `Monitor`, `TaskStop`, `SendMessage`, `Artifact`. No
`Agent`/`Task`.

So radin-execute can never run backgrounded, under any packaging: whole job is
delegation, and backgrounded run cannot dispatch single sub-agent. To free main
thread while backlog runs, start second Claude Code session and run
`/radin-execute` there -- worktree-per-task answer already keeps two sessions
off each other's checkout.
