# Technical Constraints

## Platform

- macOS + Linux only. No Windows support planned.
- Arch-neutral via Homebrew: `/opt/homebrew`/`/usr/local` on macOS
  (ARM/Intel), `/home/linuxbrew/.linuxbrew` on Linux. No `uname -m`
  branching anywhere. Resolution goes through `brew`/`npm`/`cargo` via
  `$(command -v brew)` / `brew shellenv`, which picks the right prefix for
  the machine that runs the script.
- Does a command differ by OS, not just by package-manager prefix
  (e.g. BSD `md5` on macOS vs GNU `md5sum` on Linux)? Branch on
  `command -v <tool>`, never on `uname`.

## Bash 3.2 compatibility

macOS ships `/bin/bash` 3.2 as the system bash (Apple froze it before the
GPLv3 switch). The same scripts run unmodified on Linux, where bash is
usually 4 or newer, so the macOS 3.2 sets the minimum. Every script here
(`install.sh`, future scripts) must stay bash-3.2-compatible:

- No associative arrays (`declare -A`)
- No `mapfile`
- No `${var,,}` / `${var^^}` case conversion

A dev machine with a newer bash on `PATH` breaks these rules by accident.
Test against `/bin/bash` directly, or grep for these constructs before you
commit a script change.

## The stack is opinionated, and its installs stay advisory

Installing radin installs every companion tool. There is no per-tool
question, because radin's skills cannot work on a half-installed stack and
every skill below delegates to tools it assumes are there. The installer asks
two questions. The first is execution behavior (sub-agent models), because it
changes what a run does rather than what exists. The second is which package
manager installs `rtk` (`brew`, `mise`, or its own
`curl` installer), because installing through a manager the user does
not run adds one they never chose. `radin update` keeps the recorded answer.

`install.sh` reaches each tool through an existing install path
(brew/mise/npm/pipx, a plugin marketplace, or the tool's own `curl`
installer). `codebase-memory-mcp` always uses its own installer: it resolves
OS/arch and verifies checksums.
The installer:

- Never vendors or forks their source.
- Never guarantees that a companion tool's own install command succeeds. A
  failure warns and the install continues. radin itself is unaffected.
- Asks those questions with an arrow-key picker on an interactive terminal and
  a numbered prompt otherwise. An unreadable answer takes the documented
  default. `--yes` skips the questions entirely, for a non-interactive
  machine.

There is one exception to "delegates, nothing more". When a companion
installer writes into `~/.claude` itself, radin brackets that write instead of
trusting it. `codebase-memory-mcp` installs with `--skip-config`, and
`radin-cbm-config.sh install` then runs upstream's own configuration
(`codebase-memory-mcp install -y`, which writes a skill, three graph agents, a
user-scope MCP entry and lifecycle hooks) between a snapshot and a restore.

The reason is one specific defect, not general distrust.
[#1200](https://github.com/DeusData/codebase-memory-mcp/issues/1200) replaces
the whole `SessionStart` array in `~/.claude/settings.json` instead of merging
into it, and silently drops other tools' hooks. It is open and unfixed through
v0.11.0, on a machine where caveman and ponytail both own entries in that
array. The restore puts back only what was there before and is now missing, so
it stays correct when #1200 closes: it reports `INTACT` and changes nothing.

Apply the same test to any future companion with an opinionated installer.
Install the whole tool and name exactly what it writes. If any of it is known
to be destructive, snapshot before and restore after, rather than asking the
user to choose between half a tool and a broken config.

## What radin's codebase-memory-mcp bracket does and does not cover

`radin-cbm-config.sh install` runs upstream's own configuration between a
snapshot and a restore (see `docs/architecture.md`). Its limits are
load-bearing. Read them before you change that script or tell a user they are
covered.

- **Two files, one client.** The snapshot covers `~/.claude/settings.json` and
  `~/.claude.json`. Upstream configures 45 client surfaces, and every other one
  (Cursor, Codex, Gemini CLI, OpenCode, Kiro...) takes its write unbracketed.
  Never claim that radin protects a config it never copied.
- **Restore, not rollback.** The restore adds back entries the snapshot had
  and the file now lacks. It never deletes an upstream entry, so it cannot
  undo the configuration. `codebase-memory-mcp uninstall` does that. A hook
  the user deleted after the snapshot comes back on the next `repair`.
- **Upstream's own entries are never restored.** An entry whose command names
  `codebase-memory-mcp` or a `cbm-*` shim belongs to upstream, so the restore
  skips it. Upstream rewrites that command spelling between versions (a new
  resolved config dir, a renamed shim). The rewrite reads as "dropped" and
  would otherwise pin a dead path in `SessionStart` for good, one broken
  `SessionStart:startup` hook per version the machine has seen.
- **A hook command naming a path that does not exist is pruned**, whoever
  wrote it. Two cases produce one. Upstream merges `PreToolUse` rather than
  replacing it, so its own older spelling stays. And a `~/.claude` shared
  between machines (dotfile repo, symlink to synced storage) carries the other
  machine's `$HOME`. radin cannot re-point another tool's hook, and the entry
  can only print `no such file or directory` at session start. radin never
  prunes a bare shim name, because it resolves against Claude Code's `PATH`,
  not the script's.
- **Upstream's hook scripts are stashed before its install runs.** Each one
  bakes in an absolute `BIN='<home>/.local/bin/codebase-memory-mcp'`, and
  upstream leaves an existing file alone. A shared `~/.claude` therefore keeps
  a path that fails open: the hook runs and does nothing. `install` moves
  `<config-dir>/hooks/cbm-*` into `~/.claude/.radin/backups/hooks.<stamp>/`
  so upstream has to write them again for this machine. It moves them and
  never deletes them. This is still true of v0.11.0, which writes a literal
  `BIN='/Users/<you>/.local/bin/codebase-memory-mcp'` and not `$HOME`. radin
  cannot fix those scripts in place (they are upstream's files), so the stash
  stays.
- **A stale `mcpServers` command is replaced, not kept.** `adopt_staged_mcp`
  overwrites an existing entry whose `command` is a path that does not exist,
  for the same shared-`~/.claude` reason.
- **A hook `command` must be an absolute, unquoted path.** Measured against
  Claude Code 2.1.236 and 2.1.24x. Claude Code posix_spawns a single-word hook
  command verbatim. `~/.local/bin/codebase-memory-mcp` dies with
  `ENOENT ... posix_spawn '~/.local/bin/codebase-memory-mcp'`, and so does
  upstream's quoted `'/Users/<you>/.local/bin/...'`, because the quotes are
  part of the file name. Only a command with further words (`sh ~/.claude/hooks/x`)
  reaches a shell. The earlier "`~` expands in a hook command" note measured
  that case and over-generalised it. radin wrote the `~/` form for a while and
  broke every single-word cbm hook. `restore_settings`' `normalize_cbm` now
  rewrites `cbm-*`/`codebase-memory-mcp` hook commands to absolute and
  unquoted, and it still leaves another tool's hook alone. The prune step
  handles a `~/.claude` shared between machines, not a portable spelling.
  `mcpServers.<name>.command` is posix_spawned the same way, and keeps its
  absolute path for the same reason.
- **Newest snapshot wins.** `repair` reads the newest `*.bak` pair, which
  after one successful install already contains upstream's entries. It is the
  right input after an upstream `update` and the wrong input for
  reconstructing a much older config.
- **The compiled JSON helper gates the whole path.** `lib/radin-cbm-json.c`,
  built by `install.sh` with `cc`, does every JSON read and write here. No
  compiler at install time means a binary-only install plus
  `radin hooks claude-md`. Never run upstream's configuration without a
  working restore.
- **Snapshots are the user's data.** They are plain copies under
  `~/.claude/.radin/backups/` and can contain `env` values and hook
  commands. radin never deletes one, and `radin-uninstall.sh` names the
  directory instead of removing it.
- **Uninstall is asymmetric.** `/radin-uninstall` removes radin's files.
  Upstream's skill, three agents and hooks under `~/.claude` are upstream's to
  remove.
- **`radin hooks mcp` writes a machine-specific path.** The `.mcp.json`
  entry carries the resolved binary path, so it is wrong in a shared repo on
  someone else's machine. Say so when a user asks about committing it.
- **Only names from upstream's MCP Tools table exist.** `semantic_query` is a
  `search_graph` parameter, not a tool. `detect_changes` reads the working tree,
  not an arbitrary commit.
- **A symlinked `~/.claude` is handled, not covered.** Upstream refuses
  writes under a symlinked config directory and exits 0 having configured
  nothing for Claude Code
  ([#1722](https://github.com/DeusData/codebase-memory-mcp/issues/1722)).
  `radin-cbm-config.sh install` resolves the link, passes it as
  `CLAUDE_CONFIG_DIR`, and adopts the MCP entry that override stages at
  `$CLAUDE_CONFIG_DIR/.claude.json` into `~/.claude.json`. The staged file
  stays on disk, because radin never deletes a file it did not ship. radin
  leaves a user who exports their own `CLAUDE_CONFIG_DIR` alone entirely.
- **Upstream's PATH step only tolerates zsh.** Its last install step appends
  its PATH line to the rc file of `$SHELL`. On 0.11.0 that step exits 1
  with no message under fish or bash, after Claude Code is already configured,
  and that turns a working run into `PARTIAL`. `run_upstream` passes
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

Every radin entry point is a skill, so it runs in the user's own thread and
can talk to the user. The sub-agents it dispatches cannot. Three limits apply
to those sub-agents, and all show up as a hang. The run stops mid-task, the
task stays claimed `in_progress`, and nothing is committed:

- **No prose channel.** Anything a sub-agent writes goes to the calling
  session, never to the user. So no radin prompt may send a sub-agent into a
  skill that asks in prose and waits for an answer (`/grilling`). The skill
  ends its turn, and the router sees a report with no `STATUS:` line.
- **No `AskUserQuestion`.** Claude Code removes it from every sub-agent,
  foreground and background alike, even when `tools` lists it. A sub-agent has
  no way to ask anything. This is why radin-batch is a skill rather than an
  agent: its Phase 2 gate must ask, so as an agent it could never satisfy its
  own gate.
- **No workflows, and nothing that waits on one.** The `Workflow` tool is in
  the first filter and Claude Code removes it from every sub-agent. So no
  prompt may route a sub-agent into a skill that launches one
  (`/deep-research`, any saved workflow command under `.claude/workflows/` or
  `~/.claude/workflows/`), nor into a skill that spawns its own background
  agent and waits (`/research`). Either way the sub-agent's turn ends with no
  `STATUS:` line.

Consequence: when radin needs a fact, it dispatches its own synchronous
read-only sub-agent (the Fact-finding prompt in `lib/radin-prompt-factfind.md`)
and never a third-party research skill. When radin needs a decision, the
router asks the user directly, or records the entry `blocked` and moves on.

Skill instructions the user recorded on an entry's `skills` key pass through
to the execution sub-agent unfiltered, except for this one class. Filtering
happens at the forward point in `radin state task-next`, and the Phase 5
summary names each dropped skill so the user can run it.

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

Fork mode is on by default in an interactive session (v2.1.232+), and it
removes the `run_in_background` parameter of the `Agent` tool. So no radin
prompt may tell a model to set it. A background sub-agent's result arrives as
a completion notification in a later turn. The router waits for it, never
reports a task outcome before it lands, and treats a dispatch that returns
nothing as unfinished. `attempts` is already bumped, and Phase 1's
stuck-recovery owns the task on the next run.

## Freeing the user's thread needs no radin agent

`claude agents` (agent view) dispatches full Claude Code background sessions
with the whole tool pool, a working `AskUserQuestion`, and peek, reply and
attach. `/bg` sends the current conversation there. `/radin-batch` runs
unchanged in one, so that is the route. A second `claude` session in another
terminal also works. The worktree-per-task answer keeps concurrent sessions
off each other's checkout.
