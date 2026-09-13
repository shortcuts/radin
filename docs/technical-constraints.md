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

`install.sh` offers rtk, caveman, codebase-memory-mcp through their own
existing install paths (brew/npm/pipx, or the tool's own `curl` installer).
It:

- Never vendors or forks their source.
- Never installs tool without explicit pick of yes option per tool. The one
  exception is `--yes`, which the operator typed themselves: it takes every
  tool question as yes, plus the marker-scoped `~/.claude/CLAUDE.md` guidance
  block, so one non-interactive command reproduces the same stack on the next
  machine. Behaviour questions keep their defaults.
- Every install prompt arrow-key picker on interactive terminal, numbered
  prompt otherwise. Unreadable answer takes default, never a silent yes.
- Never guarantees companion tool's own install command succeeds — it
  asks and delegates, nothing more.

One exception to "delegates, nothing more": when a companion installer writes
into `~/.claude` itself, radin brackets that write instead of trusting it.
`codebase-memory-mcp` installs with `--skip-config`, and `radin cbm-config
install` then runs upstream's own configuration (`codebase-memory-mcp install
-y` — skill, three graph agents, user-scope MCP entry, lifecycle hooks) between
a snapshot and a restore.

The reason is one specific defect, not a general distrust:
[#1200](https://github.com/DeusData/codebase-memory-mcp/issues/1200) replaces
the whole `SessionStart` array in `~/.claude/settings.json` instead of merging
into it, silently dropping other tools' hooks — open and unfixed through
v0.10.8, on a machine where caveman and ponytail both own entries in that
array. The restore puts back only what was there before and is now missing, so
it stays correct when #1200 closes: it reports `INTACT` and changes nothing.

Same test for any future companion with an opinionated installer: install the
whole tool, name exactly what it writes, and if any of it is known destructive,
snapshot before and restore after rather than asking the user to choose between
half a tool and a broken config.

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
- **No workflows, and nothing that waits on one.** `Workflow` tool is in
  first filter, removed from every sub-agent. So no prompt may route
  sub-agent into skill that launches one (`/deep-research`, any saved
  workflow command under `.claude/workflows/` or `~/.claude/workflows/`), nor
  into skill that spawns own background agent and waits (`/research`) --
  sub-agent's turn ends with no `STATUS:` line either way.

Consequence: when radin needs fact, it dispatches own synchronous read-only
sub-agent (Fact-finding prompt in `lib/radin-execute-prompts.md`) -- never
third-party research skill. When radin needs decision, router asks user
directly, or records entry `blocked` and moves on.

`**Skill:**` pointers user recorded pass through to execution sub-agent
unfiltered except for this one class. Filtering happens at forward point in
`skills/radin-execute/SKILL.md` Step 4b, and dropped skill named in Phase 5
summary so user can run it themselves.

## Background sub-agents keep a smaller built-in tool set

Second filter cuts background sub-agent's built-ins to: `Read`, `Grep`,
`Glob`, `Bash`, `PowerShell`, `Edit`, `Write`, `NotebookEdit`, `WebFetch`,
`WebSearch`, `TodoWrite`, `Skill`, `ToolSearch`, `EnterWorktree`,
`ExitWorktree`, `Monitor`, `TaskStop`, `SendMessage`, `Artifact`, plus every
MCP tool.

`Agent` is **not** cut by that filter. Docs carve it out explicitly: "Apart
from `Agent` and `ExitPlanMode`, which follow the first filter's conditions
wherever the sub-agent runs". First filter drops `Agent` only at depth limit
(default 3) or in fork. So background sub-agent at depth 1 delegates
normally. Don't read `Agent`'s absence from second filter's list as removal.

## Nobody picks foreground or background

Fork mode is on by default in interactive session (v2.1.232+), and it removes
`Agent` tool's `run_in_background` parameter. So no radin prompt may tell a
model to set it. Background sub-agent's result arrives as completion
notification in later turn. Router waits for it, never reports task outcome
before it lands, and treats a dispatch that returns nothing as unfinished --
`attempts` is already bumped and Phase 1's stuck-recovery owns it next run.

## Freeing the user's thread needs no radin agent

`claude agents` (agent view) dispatches full Claude Code background sessions:
whole tool pool, working `AskUserQuestion`, peek/reply/attach. `/bg` sends
current conversation there. `/radin-execute` runs unchanged in one, so that's
the route. Second `claude` session in another terminal works too --
worktree-per-task answer keeps concurrent sessions off each other's checkout.
