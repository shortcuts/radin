# Architecture

## What radin is

Claude Code plugin — agents, skills, install glue — dist as git repo, install via `install.sh`. No runtime language, bash only, macOS/Linux (via Homebrew/Linuxbrew — see `AGENTS.md` arch-neutrality rule).

## Storage model

All radin state — backlog content, execution state — lives inside target repo, one dir at repo root:

```
<repo-root>/.claude/.radin/
  backlog/
    index.jsonl                  # backlog index, source of truth: one JSON object per task
    tasks/
      <task-id>.md                # one file per task: description + any **Plan:** lines
      <epic-id>/
        DESCRIPTION.md            # the epic's root context, inherited by every child task
        <task-id>.md              # a child task of that epic
  state/
    BACKLOG_STEPS.json          # radin-execute execution plan
    completed.json               # radin-execute completed-task -> commit log
    session.json                 # radin-execute worktree/branch answers, one per run
    journal.jsonl                # append-only log of every state transition
    facts/
      <task-id>.md                # long-form evidence for one task, when a report won't fit inline
  plans/
    <task-id>.md                # radin-plan output, one file per plan
  reviews/
    <review-name>.md            # radin-review / thermo-nuclear output
```

An epic is that one directory level and nothing else: membership is carried by the index line's `file` field (`tasks/<epic-id>/<task-id>.md`), so an epic gets no index line and no category. A line would have to be filtered out of `list` by every consumer, and the first one that forgot would dispatch an epic as a task. One nesting level: no epics inside epics. Task ids stay globally unique across every epic — `depends_on`, `radin state prepare`, `task-dir`, `triage` and the `radin/<task-id>` branch all key off the bare id.

Split each task into own file, not one monolithic doc: no radin agent/skill addresses backlog content by line number — `**Plan:**` insert into one task's file can't touch any other task's file. `index.jsonl` = JSON Lines — one compact object per line, `{"id":...,"category":...,"title":...,"file":...}` — not single JSON array. Bash 3.2 got no JSON parser, project got no `jq` dep, so one-object-per-line keeps every CLI op a grep/sed one-liner.

Outside any git repo, current directory takes repo root's place.

Replaced earlier `~/.claude/.radin/projects/<repo-slug>/` scheme. That scheme kept target repos untouched, but hashed slug one abstraction too many: agent resolving it (haiku, default) had to trust opaque mapping instead of path it can see. In-repo state removes mapping. Backlog always at `.claude/.radin/` in repo worked on. Commit or gitignore it — consumer's call, radin never touches `.gitignore`. Old `~/.claude/.radin/projects/` data not migrated.

## Namespace resolution and the backlog CLI

Every one of `skills/radin-execute/SKILL.md`, `skills/radin-plan/SKILL.md`, `skills/radin-review/SKILL.md`, `skills/radin-record/SKILL.md`, `skills/radin-show/SKILL.md` goes through same shared CLI, `lib/radin-backlog.sh`, for every deterministic backlog op:

```bash
radin backlog <env|show|list|count|find|add|add-plan|append|meta|planned|path|set-category|retitle|set-priority|set-deps|remove|reconcile|epics|epic-add|epic-show|epic-move|epic-remove>   # dispatcher at ~/.claude/.radin/bin/radin, symlinked into ~/.local/bin
```

The subcommand is what switches the two modes apart, so no flag does. `radin <verb> ...` is the agent and power-user entry point. Bare `radin` is the human one: on a terminal it is exactly `radin tui` (missing-binary message included), and off one it prints the usage text and exits non-zero, because a skill or pipe trapped in a full-screen app would hang the agentic loop until a timeout. `radin help` is the documented way to get that text.

- `env` — namespace resolution (delegates to `lib/radin-namespace.sh`, single source of truth for path logic; prints `REPO_ROOT`, `NAMESPACE_DIR`, `BACKLOG_INDEX`, `BACKLOG_TASKS_DIR`)
- `show [category]` — render backlog as markdown (all tasks, or one category), reconstructed from `index.jsonl` + each task's file
- `list` — print `id<US>category<US>title<US>file<US>priority<US>depends-on-csv` per task, ordered by priority descending with unset priorities last
- `find <id-or-title>` — locate task, print the same six fields per match (exact id first, then exact title, else case-insensitive substring on title)
- `add <category> <title> [--epic <epic-id>] [--priority <n>] [--depends-on <csv>]` — create task (body on stdin): slugifies title into id (dedupe on collision against the index's `id` fields), writes file, appends one line to index
- `add-plan <id-or-title> <path>` — append `**Plan:**` pointer to task's own file
- `planned` — print the id of every task whose file already carries a `**Plan:**` line; one call answers "which tasks are planned?" for a whole listing, where `meta` per task costs one file read each
- `path <id-or-title>` — print task file's absolute path, resolved by reading matched index line's `file` field and joining it to `backlog/` (what `radin tui` reads and hands to `$EDITOR`)
- `set-category <id-or-title> <category>` / `retitle <id-or-title> <title>` — rewrite that one index line, id and task file untouched (id stays stable for the task's lifetime, so a retitle can't orphan a `depends_on` or a plan pointer)
- `set-priority <id-or-title> <integer|--none>` / `set-deps <id-or-title> <csv-of-ids|--none>` — store the human's ranking and ordering on the index line; `set-deps` refuses an unknown id, a self-reference and a cycle, because an unresolvable dependency stalls `radin state deps-check` instead of failing it
- `remove <id-or-title>` — delete task's file + index line (exact single match required); drops the epic directory too when that was its last child, so `epics` never reports a husk, and prunes the removed id from every other entry's `depends_on`
- `epics` — print every epic id, one per line; a directory listing, because an epic index file would be a second store to keep in sync
- `epic-add <epic-id>` — create the directory and its `DESCRIPTION.md` (body from stdin when piped)
- `epic-show <epic-id>` — print the epic's `DESCRIPTION.md` verbatim (nothing, exit 0, when it is empty)
- `epic-move <id-or-title> <epic-id|--none>` — move the task file and rewrite its `file` field; `--none` returns it to the flat `tasks/` level
- `epic-remove <epic-id>` — refuse while child tasks remain (exit non-zero, delete nothing): the operator moves them out first

Point: offloading. Id assignment, task lookup, plan-pointer insertion — deterministic ops model used to re-derive from prose rules every run. CLI does them exact; agents/skills supply only judgment (what to log, how to classify, what to plan). Task's file path always read back from its index line's `file` field, never composed by a caller and never computed from stored line number — nothing here goes stale as backlog shape changes.

`install.sh` copies `lib/radin-namespace.sh`, `lib/radin-backlog.sh`, `lib/radin-state.sh` to `~/.claude/.radin/lib/`, and `bin/radin` — a dispatcher mapping `radin <backlog|tui|state|scope|cbm-hooks|cbm-config|update|doctor|uninstall>` to those scripts — to `~/.claude/.radin/bin/`, plus a `~/.local/bin/radin` symlink (an existing non-radin file there is named and left alone, and skills then get the full dispatcher path). Consumer install never has this repo's `lib/` directly, so the scripts dist like any other radin file.

Inside script:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
[ -n "$REPO_ROOT" ] || REPO_ROOT="$PWD"
NAMESPACE_DIR="$REPO_ROOT/.claude/.radin"
```

Creates `state/`, `plans/`, `reviews/`, `backlog/tasks/` under `$NAMESPACE_DIR`, then prints four vars with `printf %q` — output stays source-able even when repo path has spaces.

`radin-execute`'s own state files (`BACKLOG_STEPS.json`, `completed.json`) get same treatment as backlog. Sibling CLI, `lib/radin-state.sh`, only way agent mutates either file — never hand-written JSON edit in agent's own prose.

```bash
radin state <start|stuck|triage|set-status|remove|completed-add|completed-get|completed-list|task-dir|prepare|dirty-check|session-set|session-get|journal-tail>
```

- `start <steps-file> <id>` — claim task before dispatch: `status` `in_progress`, `attempts` +1. Exits 2 having marked entry `blocked` once `attempts` passes `MAX_ATTEMPTS` (3), so crash loop can't burn tokens forever
- `stuck <steps-file>` — list `in_progress` entries: tasks dispatched by run that died before terminal status. Recovery entry point
- `triage <namespace-dir> <id>` — facts about what dead sub-agent left: `attempts`, `completed` hash, `worktree`, `branch`, `branch_commit` lines, `dirty_files` count. Prints facts, decides nothing — agent routes on them (see `radin-execute` Phase 1 step 3). Worktree path and branch name derived from task id, never recorded: execution prompt pins them to `../<repo>-<id>` / `radin/<id>`
- `set-status <steps-file> <id> <pending|in_progress|failed|blocked> [note]` — rewrite one entry's `status`/`note` in place, `order`/`depends_on`/`attempts` untouched
- `remove <steps-file> <id>` — delete one completed entry's line
- `completed-add <completed-file> <id> <hash>` — append completed task's commit, create file if absent
- `completed-get <completed-file> <id>` — print completed task's commit hash (exit 1 if not recorded), for later task's `depends_on` check
- `completed-list <completed-file>` — print `id<TAB>commit` per completion in file order (exit 1 when nothing is recorded), for `radin tui`'s Done view: completion deletes the backlog entry, so this file is the only record left
- `task-dir <repo-root> <id>` — print task's worktree (`<repo-root>-<id>`) when it exists, else repo root. Everything checking or parking one task's files (`dirty-check`, `stash`) goes through it: in worktree mode repo root is not tree sub-agent worked in, and checking wrong one reports clean while work sits uncommitted elsewhere
- `prepare <namespace-dir> <id>` — read `session.json`, create or reuse `<repo-root>-<id>` worktree and `radin/<id>` branch exactly as recorded answers require, print single directory execution sub-agent works in. Only place those two answers turn into git commands, so a model can't reinterpret `no` into a worktree it prefers. Fails when nothing recorded yet
- `dirty-check <dir>` — `git status --porcelain`, `.claude/.radin` excluded so radin's own state writes never read as dirty tree
- `session-set`/`session-get <namespace-dir>` — persist and read Phase 0.5's worktree/branch answers, so resumed run reuses them instead of asking again and splitting session between worktrees and checkout. `prepare` consumes them; orchestrator only reads them back for its final summary
- `journal-tail <namespace-dir> [n]` — last n events from append-only `state/journal.jsonl`, written by every mutation above. Lets agent reconstruct what session already did after context compaction. Forensics only, never control flow

Both `BACKLOG_STEPS.json` and `completed.json` JSONL (one compact object per line), same convention as backlog's `index.jsonl` — single-entry edit never risks another line, model never parses/rewrites bracketed JSON array by hand.

`radin-execute` and `radin-plan` skill also share `lib/radin-prioritization.md`, single source of truth for backlog parsing rules, task priority criteria, state-file JSON schema. Both read via `$HOME/.claude/.radin/lib/radin-prioritization.md` — `radin-execute` at start of Phase 1, `radin-plan` at start of its Step 2 — instead of embedding own copy. `radin-execute` uses all of it, prioritize/order whole backlog. `radin-plan` uses only parsing section: scoped to single entry caller points at, not whole backlog, so nothing to prioritize, no state file of own.

`radin-execute` alone reads three on-demand files, none of them inline in `SKILL.md`, because the skill body sits in the user's own context for the rest of the session:

- `lib/radin-execute-prompts.md` — the four verbatim sub-agent prompts (planning, execution, debug, fact-finding), read at start of Phase 4. A session that stops at Phase 2 (common first turn) never reaches Phase 4, so never loads them.
- `lib/radin-execute-recovery.md` — `triage` routing for tasks a dead session left `in_progress`, read only when `radin-state.sh stuck` exits 0. Most runs never load it.
- `lib/radin-execute-reporting.md` — residual-changes check, commit-location rules, final report template, read at Phase 5.

## Why every entry point is a skill

radin-execute was an agent (`agents/radin-execute.md`) until it became a skill. Two Claude Code capability limits forced the move, both documented in `docs/technical-constraints.md`:

- `AskUserQuestion` removed from **every** sub-agent, foreground and background alike. Agent's Phase 2 gate asks user to confirm execution order, so as agent it could never actually ask — every run fell back to ending its turn with question and waiting to be re-invoked.
- Sub-agent's prose reaches only calling session, never user. So agent's own report needed re-summarizing by main thread, and every question had to be encoded as `blocked` backlog state instead of asked.

As skill, radin-execute runs in user's own thread: asks directly, gets interrupted, resumes from disk. Sub-agents stay, one layer down, as leaf workers — that's where context isolation earns its keep (planning's codebase exploration, execution's edits, review's diff read), each returning single `STATUS:` line. Same split SOTA skill collections use: orchestrate in main thread, isolate leaf work.

### Running the backlog in the background

radin ships no agent for this. `claude agents` (agent view) dispatches full Claude Code background sessions — whole tool pool, working `AskUserQuestion`, peek/reply/attach — and `/radin-execute` runs unchanged in one. `/bg` sends the current conversation there. A second `claude` session in another terminal works too.

`radin-plan` is skill, not agent: runs inline in whichever context invokes it. In user's own conversation, judges whether its one scoped entry should split into independent sub-plans, confirms with user directly before splitting, writes plan file + `**Plan:**` pointer per resulting sub-task. For any task reaching Phase 3 with no `**Plan:**` line yet, `radin-execute` delegates planning to dedicated planning sub-agent invoking `/radin-plan`. Keeps planning's codebase exploration out of orchestrator's context — plan file on disk = handoff to execution sub-agent. That sub-agent runs non-interactively: where skill would ask confirmation, takes non-destructive path (no split, no overwrite), genuine ambiguity marks task `blocked` for user instead of guessing.

### Updating the stack

`radin update` (`lib/radin-update.sh`) is the one update path, and it needs no model — same reasoning as `radin doctor` and `radin uninstall`. It reads `~/.claude/.radin/install_root`, which `install.sh` writes every run:

- source has a `.git` dir (dev clone): `git pull --ff-only`, refusing outright when `git status --porcelain` prints anything, then `bash "$SRC/install.sh" --update`.
- anything else (tarball install, or an install predating `install_root`): download the newest `install.sh` from `main` and run it with `--update`, since that installer re-resolves the latest release tarball itself.

`--update` implies `--force` and `--yes`, so every companion tool takes its upgrade path and no behaviour question is re-asked. Instead `install.sh` reads its own previous `manifest.json` (`manifest_value`, a `sed` lookup — no JSON parser) for `parallel_execution` and the five `model_<role>` keys, and writes those answers back into the installed files. Models are all-or-nothing: a manifest missing any of the five falls through to the pickers, so a half-read manifest can't mix recorded picks with defaults. No manifest at all (first install with `--update`) means the documented defaults, never a blocking prompt.

Non-destructive by construction: the installer only `cp`s radin's own files, plugins go through `claude plugin update`, brew/pipx installs re-run as upgrades, and `radin cbm-config install` re-brackets upstream's `settings.json` write with a fresh snapshot. `--force` alone still works, and still asks the three questions.

## Code-graph wiring (codebase-memory-mcp)

`codebase-memory-mcp` is radin's code-intelligence companion: an MCP server that indexes a repo into a persistent knowledge graph, so `radin-plan`, `radin-review` and execution sub-agents ask the graph (`search_graph`, `trace_path`, `get_code_snippet`, `query_graph`, `detect_changes`) instead of grepping files.

`install.sh` installs the binary with **`--skip-config`**, sets `auto_index true`, then runs `radin cbm-config install`, which is upstream's own `codebase-memory-mcp install -y`: its skill, three tiered graph agents (Scout/Verify/Auditor), the user-scope MCP entry in `~/.claude.json`, and the `SessionStart`/`SubagentStart`/`PreToolUse` hooks that route Grep/Glob toward the graph. User-scope MCP is why no per-project step is needed afterwards, and `--skip-config` on the binary install only defers that write so radin can bracket it.

`lib/radin-cbm-config.sh` is the bracket. Upstream [#1200](https://github.com/DeusData/codebase-memory-mcp/issues/1200) — open, maintainer-confirmed, unfixed through v0.10.8 — replaces the whole `SessionStart` array in `~/.claude/settings.json` rather than merging into it, dropping any hook another tool owns. So the script:

1. copies `settings.json` and `~/.claude.json` into `~/.claude/.radin/backups/<name>.<timestamp>.bak` (copies only; radin never deletes one),
2. runs `codebase-memory-mcp install -y`,
3. restores, per hook event, every snapshot entry that is now missing — pre-existing entries first, upstream's after — plus any dropped top-level `settings.json` key and any dropped `mcpServers` entry,
4. prints one `RESTORED`/`INTACT` line per item and a final line saying whether upstream's hooks and MCP entry actually landed.

Entries are compared deep-equal, so re-running restores nothing and reports `INTACT`. A failed upstream install still gets step 3, because its configuration pass is transactional per client, not per file. `radin cbm-config repair` runs steps 3-4 alone against the newest snapshot, which is what to use after `codebase-memory-mcp update` reruns the same write. Every JSON read and write on this path is the compiled helper `lib/radin-cbm-json.c` (built into `~/.claude/.radin/bin/radin-cbm-json`), so `radin-cbm-config.sh` holds no JSON knowledge of its own: it snapshots with `cp`, stashes with `mv`, runs upstream, and calls the helper three times. A C compiler is therefore required for this path; without one `install.sh` skips upstream's configuration and falls back to the merge-only wiring, on the grounds that running a destructive write with no restore is worse than a smaller install.

`lib/radin-cbm-hooks.sh` (dispatched as `radin cbm-hooks <claude-md|mcp|all>`, driven by the `radin-setup-hooks` skill) is the fallback for the no-compiler path, and for anyone who ran `codebase-memory-mcp uninstall` but kept radin. Two writes, merge-only, skipping anything already defined:

- the `codebase-memory-mcp` MCP-tools section in `~/.claude/CLAUDE.md`
- `mcpServers.codebase-memory-mcp` in `<repo-root>/.mcp.json`, pointing at the resolved binary path

It writes no `settings.json` hook of radin's own: `auto_index` indexes a project on first connection and the background watcher keeps it current, so a `PostToolUse` reindex would pay for nothing. The graph itself lives in `~/.cache/codebase-memory-mcp/`, outside both `~/.claude` and the consumer's repo.

An MCP tool name must exist in upstream's [MCP
Tools](https://github.com/DeusData/codebase-memory-mcp#mcp-tools) table — a
wrong one costs a failed call plus a fallback in every sub-agent that reads
the prompt. Names appear in four files only:
`skills/radin-plan/SKILL.md` (exploration), `skills/radin-review/SKILL.md`
(`detect_changes` first), `lib/radin-execute-prompts.md` (execution, debug,
fact-finding), and the CLAUDE.md section inside `lib/radin-cbm-hooks.sh`.
Between them they name `index_repository`, `list_projects`, `search_graph`,
`search_code`, `trace_path`, `detect_changes`, `query_graph`,
`get_graph_schema`, `get_code_snippet` and `get_architecture`. Each mention
also says a graph hit is a pointer: read the file before editing, never claim
absence from an empty result.

## Install manifest

`install.sh` writes `~/.claude/.radin/manifest.json` every run: generated snapshot of what installed. Records `version` (release tag, or `dev` for local git clone), `installed_at` (UTC timestamp), `skills`/`lib` file lists copied, `parallel_execution` (whether install allowed `radin-execute` to fan out execution sub-agents), `install_root` and the five `model_<role>` keys (both read back by `install.sh --update`), `claude_md_guidance` (whether the radin section in `~/.claude/CLAUDE.md` was written), `cbm_agent_config` (whether upstream's own `codebase-memory-mcp install` ran), `cli_on_path` (whether the symlink landed), `companion_tools` object recording which of rtk, codebase-memory-mcp, headroom, caveman, ponytail, mattpocock-skills came out reachable — a companion install is advisory, so `false` means its own installer failed or its CLI is missing.

Snapshot for external tooling to read, not live source of truth. `radin-doctor.sh` and `radin-uninstall.sh` each keep own independent file list, check filesystem direct, rather than trust manifest. Corrupted or stale manifest must never make either report false "OK" or delete wrong thing.

## Plugin repo layout

```
radin/
  .claude-plugin/
    plugin.json
  skills/
    radin-execute/
      SKILL.md
    radin-plan/
      SKILL.md
    radin-doctor/
      SKILL.md
    radin-review/
      SKILL.md
    radin-record/
      SKILL.md
    radin-show/
      SKILL.md
    radin-setup-hooks/
      SKILL.md
    radin-stats/
      SKILL.md
    radin-uninstall/
      SKILL.md
  docs/
  bin/
    radin
  lib/
    radin-backlog.sh
    radin-tui.c
    radin-cbm-json.c
    radin-cbm-hooks.sh
    radin-doctor.sh
    radin-update.sh
    radin-execute-prompts.md
    radin-execute-recovery.md
    radin-execute-reporting.md
    radin-namespace.sh
    radin-prioritization.md
    radin-state.sh
    radin-uninstall.sh
  install.sh
  README.md
```

## The human TUI

`radin tui` — or bare `radin` on a terminal — (`lib/radin-tui.c`) is the human's way into the same backlog the
skills drive: a full-screen list of every task, a preview of the selected
task's body, and one key per operation (`e` edit in `$EDITOR`, `v` view in
`$PAGER`, `a` new, `d` delete, `c` next category, `r` retitle, `/` search).
A `P` in the first column marks a task `radin-plan` already planned. A `*`
marks a row matching the active `/` search, and `n`/`N` walk those matches.

Three rules keep it from becoming a second backlog implementation:

- **It draws and dispatches keys, nothing else.** Every mutation shells out to
  `radin-backlog.sh` (`add`, `remove`, `set-category`, `retitle`, `set-deps`,
  `epic-move`), so the index/task-file contract has exactly one owner. A key
  that needs an operation the CLI lacks means adding a CLI subcommand, not
  writing to `index.jsonl` from the TUI.
- **Raw ANSI only — no ncurses, `tput`, `dialog`, `gum` or `fzf`.** Zero
  dependencies is the same promise as the rest of radin: `termios` for raw mode,
  `TIOCGWINSZ` for the terminal size, `\033[` escapes to draw.
- **C, not bash — one of the two compiled files radin ships** (`lib/radin-cbm-json.c`, the JSON surgery behind `radin cbm-config`, is the other). A bash frame cost a fork
  per row and ~150ms per keypress-to-frame, and the TUI's 43 pty tests were a
  third of the suite's runtime. `install.sh` builds it with `cc` (Command Line
  Tools on macOS, gcc on Linux) into `~/.claude/.radin/bin/radin-tui`; the build
  is advisory like a companion tool, so a box with no compiler keeps every other
  subcommand and `radin backlog show`.

It is deliberately not a skill and no agent invokes it: a TUI needs a terminal
and a human at it, and every agent-facing path already exists as a CLI
subcommand. `install.sh` asks nothing about it.

## Authoring vs. distribution

This repo source of truth. `skills/*/SKILL.md` authored/edited direct here — no external fork, no sync step. `install.sh` dist them one-directional into `~/.claude/skills`. Every entry point is a skill, so it runs in the user's own thread and can talk to them (see "Why every entry point is a skill"). `thermo-nuclear` not part of this repo at all: `install.sh` downloads its `SKILL.md` straight from cursor/plugins at install time.

## Install-time substitution

Three things no radin file may state literally. `install.sh` writes each one
in, and each substitution exits non-zero if its token survives — a file that
ships with the token intact invents its own answer.

| Written as | Resolved to |
| --- | --- |
| `RADIN_CLI <subcommand>` in every `skills/*/SKILL.md` and shipped `lib/*.md` | bare `radin` when the `~/.local/bin` symlink is on PATH, else `"$HOME/.claude/.radin/bin/radin"` (`set_cli`) |
| `RADIN_MODEL_<ROLE>` — `PLANNING`, `EXECUTION`, `DEBUG`, `FACTFIND` in `lib/radin-execute-prompts.md`, `REVIEW` in `skills/radin-execute/SKILL.md` | the install-time pick (`set_role_models`). Defaults sonnet, except fact-finding: haiku, since its prompt demands the evidence and the router can reject a wrong answer |
| one `<!-- radin:concurrency -->` line in `radin-execute`'s Core Constraints | `$SEQUENTIAL_RULE` or `$PARALLEL_RULE`, both defined only in `install.sh` (`set_concurrency`) |

Edit the concurrency wording in `install.sh`, never in the skill. A new
sub-agent role needs a token, a `MODEL_<ROLE>` default, a picker, and a `-e`
clause in `set_role_models`.

Sub-agent prompts carry no concurrency variant: `lib/radin-execute-prompts.md`
states the flat rule (a sub-agent never spawns a sub-agent) instead. The
install-time answer covers execution sub-agents only — planning, debug and
fact-finding dispatches write no repo code, so both rule texts allow them in
parallel unconditionally.

Any new install-time question must also be recorded in `manifest.json`, or the
next `radin update` resets it.

## Verification in radin-execute

There is none per task, deliberately. A `STATUS: SUCCESS` goes straight to the
bookkeeping, and `/radin-review` at Phase 6 is the session's one verification
pass. A per-task refuter sub-agent used to run here; it cost an extra
sub-agent per successful task for findings the Phase 6 pass finds anyway.
Don't reintroduce one, and don't have the router re-read the diff instead —
that read is the cost the single end-of-session pass exists to avoid.

A task body may state its own `**Acceptance:**` criteria, which
`radin backlog meta` reports and the execution prompt is handed. A task with
no criteria adds no prompt content: a synthesised criterion would measure the
work against radin's own guess.

## Delegation is pinned by a test

`tests/skill-names.bats` pins every `/<name>` written in `skills/**/SKILL.md`
and `lib/*.md` to a skill radin ships or `install.sh` installs, so a rename or
typo fails the suite instead of costing a failed call in every sub-agent. A
new companion needs its plugin prefix in that test's list.
