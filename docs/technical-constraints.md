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

## The stack is opinionated, and its installs stay advisory

Installing radin installs every companion tool. There is no per-tool
question: a half-installed stack is the case radin's skills cannot rely on,
and every skill below delegates to tools it assumes are there. Two
questions are asked: execution behaviour (sub-agent models),
because it changes what a run does rather than what exists, and which
package manager installs `rtk` and `headroom` (`brew`, `mise`, or each
tool's own `curl`/`pipx` installer), because installing through a manager
the user does not run adds one they never chose. `radin update` reuses the
recorded answer.

`install.sh` reaches each tool through an existing install path
(brew/mise/npm/pipx, a plugin marketplace, or the tool's own `curl`
installer). `codebase-memory-mcp` always uses its own installer: it resolves
OS/arch and verifies checksums.
It:

- Never vendors or forks their source.
- Never guarantees a companion tool's own install command succeeds. A failure
  warns and the install continues; radin itself is unaffected.
- Asks those questions with an arrow-key picker on an
  interactive terminal, a numbered prompt otherwise. An unreadable answer
  takes the documented default. `--yes` skips them entirely, for a
  non-interactive machine.

One exception to "delegates, nothing more": when a companion installer writes
into `~/.claude` itself, radin brackets that write instead of trusting it.
`codebase-memory-mcp` installs with `--skip-config`, and `radin-cbm-config.sh
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

## What radin's codebase-memory-mcp bracket does and does not cover

`radin-cbm-config.sh install` runs upstream's own configuration between a
snapshot and a restore (see `docs/architecture.md`). Its limits are load-
bearing — read them before changing that script or telling a user they are
covered.

- **Two files, one client.** The snapshot is `~/.claude/settings.json` and
  `~/.claude.json`. Upstream configures 45 client surfaces; every other one
  (Cursor, Codex, Gemini CLI, OpenCode, Kiro...) takes its write unbracketed.
  Don't claim radin protects a config it never copied.
- **Restore, not rollback.** The restore adds back entries the snapshot had
  and the file now lacks. It never deletes an upstream entry, so it cannot
  undo the configuration — `codebase-memory-mcp uninstall` does that. A hook
  the user deleted after the snapshot comes back on the next `repair`.
- **Upstream's own entries are never restored.** An entry whose command names
  `codebase-memory-mcp` or a `cbm-*` shim belongs to upstream, so the restore
  skips it. Upstream rewrites that command spelling between versions (a new
  resolved config dir, a renamed shim), which reads as "dropped" and would
  otherwise pin a dead path in `SessionStart` for good — one broken
  `SessionStart:startup` hook per version the machine has seen.
- **A hook command naming a path that does not exist is pruned**, whoever
  wrote it. Two ways one appears: upstream merges `PreToolUse` rather than
  replacing it, so its own older spelling stays; and a `~/.claude` shared
  between machines (dotfile repo, symlink to synced storage) carries the other
  machine's `$HOME`. radin cannot re-point another tool's hook, and the entry
  can only print `no such file or directory` at session start. A bare shim
  name is never pruned — it resolves against Claude Code's `PATH`, not the
  script's.
- **Upstream's hook scripts are stashed before its install runs.** Each one
  bakes in an absolute `BIN='<home>/.local/bin/codebase-memory-mcp'` and
  upstream leaves an existing file alone, so a shared `~/.claude` keeps a path
  that fails open — the hook runs and does nothing. `install` moves
  `<config-dir>/hooks/cbm-*` into `~/.claude/.radin/backups/hooks.<stamp>/`
  so upstream has to write them again for this machine. Moved, never deleted.
  Still true of v0.10.8, which writes a literal
  `BIN='/Users/<you>/.local/bin/codebase-memory-mcp'` and not `$HOME`; radin
  cannot fix those scripts in place (they are upstream's files), so the stash
  stays.
- **A stale `mcpServers` command is replaced, not kept.** `adopt_staged_mcp`
  overwrites an existing entry whose `command` is a path that does not exist,
  for the same shared-`~/.claude` reason.
- **A hook `command` must be an absolute, unquoted path.** Measured against
  Claude Code 2.1.236 and 2.1.24x. Claude Code posix_spawns a single-word hook
  command verbatim: `~/.local/bin/codebase-memory-mcp` dies with
  `ENOENT ... posix_spawn '~/.local/bin/codebase-memory-mcp'`, and so does
  upstream's quoted `'/Users/<you>/.local/bin/...'` — the quotes are part of
  the file name. Only a command carrying further words (`sh ~/.claude/hooks/x`)
  reaches a shell, which is what the earlier "`~` expands in a hook command"
  note measured and over-generalised; radin wrote the `~/` form for a while and
  broke every single-word cbm hook. `restore_settings`' `normalize_cbm` now
  rewrites `cbm-*`/`codebase-memory-mcp` hook commands to absolute and
  unquoted, and another tool's hook is still left alone. A `~/.claude` shared
  between machines is handled by the prune step, not by a portable spelling.
  `mcpServers.<name>.command` is posix_spawned the same way, and keeps its
  absolute path for the same reason.
- **Newest snapshot wins.** `repair` reads the newest `*.bak` pair, which
  after one successful install already contains upstream's entries. It is the
  right input after an upstream `update`, and the wrong input for
  reconstructing a much older config.
- **The compiled JSON helper gates the whole path.** Every JSON read and write
  here is `lib/radin-cbm-json.c`, built by `install.sh` with `cc`. No compiler
  at install time means binary-only install plus `radin hooks claude-md`.
  Never run upstream's configuration without a working restore.
- **Snapshots are the user's data.** Plain copies under
  `~/.claude/.radin/backups/`, possibly containing `env` values and hook
  commands. radin never deletes one, and `radin-uninstall.sh` names the
  directory instead of removing it.
- **Uninstall is asymmetric.** `/radin-uninstall` removes radin's files.
  Upstream's skill, three agents and hooks under `~/.claude` are upstream's to
  remove.
- **`radin hooks mcp` writes a machine-specific path.** The `.mcp.json`
  entry carries the resolved binary path, so it is wrong in a shared repo on
  someone else's machine. Say so when a user asks about committing it.
- **Only names from upstream's MCP Tools table exist.** `semantic_query` and
  `check_index_coverage` appear in upstream prose but not in that table; they
  are not safe to name in a prompt. `detect_changes` reads the working tree,
  not an arbitrary commit.
- **A symlinked `~/.claude` is handled, not covered.** Upstream refuses
  writes under a symlinked config directory and exits 0 having configured
  nothing for Claude Code
  ([#1722](https://github.com/DeusData/codebase-memory-mcp/issues/1722)).
  `radin-cbm-config.sh install` resolves the link, passes it as
  `CLAUDE_CONFIG_DIR`, and adopts the MCP entry that override stages at
  `$CLAUDE_CONFIG_DIR/.claude.json` into `~/.claude.json`. The staged file
  stays on disk — radin never deletes a file it did not ship. A user who
  exports their own `CLAUDE_CONFIG_DIR` is left alone entirely.
- **Upstream's PATH step only tolerates zsh.** Its last install step appends
  its PATH line to the rc file of `$SHELL`, and on 0.11.0 that step exits 1
  with no message under fish or bash, after Claude Code is already configured
  — which is what turns a working run into `PARTIAL`. `run_upstream` passes
  `SHELL=/bin/sh`, so the line lands in `~/.profile` and the run finishes.
  radin's own `radin` symlink does not depend on it.
- **An upstream exit 0 is not proof of configuration.** `cbm_wired` checks
  `settings.json` for a `cbm-*` hook and `~/.claude.json` for the MCP entry,
  and `install` fails when both are absent. It matches on names, so an
  upstream rename of those shims reads as "absent" until this check is
  updated.
- **The bracket survives the fix.** When #1200 closes, the restore finds
  nothing missing and prints `INTACT`. Leave it in place; the same code keeps
  covering the next regression in that write.

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

Skill instructions user recorded on entry's `skills` key pass through to
execution sub-agent unfiltered except for this one class. Filtering happens at forward point in
`radin state task-next`, and dropped skill named in Phase 5
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
