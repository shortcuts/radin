# Architecture

## What radin is

Claude Code plugin — agents, skills, install glue — dist as git repo, install via `install.sh`. No runtime language, bash only, macOS/Linux (companion tools via the package manager the install asks for — see `AGENTS.md` arch-neutrality rule).

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
radin backlog <env|show|list|count|find|add|add-plan|append|meta|planned|order|field|duplicates|path|plan-target|set-category|retitle|set-priority|set-deps|remove|reconcile|epics|epic-add|epic-show|epic-move|epic-remove>   # dispatcher at ~/.claude/.radin/bin/radin, symlinked into ~/.local/bin
```

The subcommand is what switches the two modes apart, so no flag does. `radin <verb> ...` is the agent and power-user entry point. Bare `radin` is the human one: on a terminal it execs the TUI (missing-binary message included), and off one it prints the usage text and exits non-zero, because a skill or pipe trapped in a full-screen app would hang the agentic loop until a timeout. `radin help` is the documented way to get that text.

- `env` — namespace resolution (delegates to `lib/radin-namespace.sh`, single source of truth for path logic; prints `REPO_ROOT`, `NAMESPACE_DIR`, `BACKLOG_INDEX`, `BACKLOG_TASKS_DIR`)
- `show [category]` — render backlog as markdown (all tasks, or one category), reconstructed from `index.jsonl` + each task's file
- `list` — print `id<US>category<US>title<US>file<US>priority<US>depends-on-csv` per task, ordered by priority descending with unset priorities last. That order is the human's ranking, not a display choice, and it is what `order` consumes as its baseline; `--order created` gives `index.jsonl` line order instead, and the default stays `priority` so no agent pays a flag for it
- `order <--rank-needed|--report|--steps> [--rank <csv>] [--infer-deps <id>=<csv>]... [--defer <csv>]` — the execution order, whole. The priority order `list` defaults to is what it consumes, plus the topological dependency fix; `--rank-needed` is the "does the ranking pass run at all" gate (exit 1 = every priority set), `--report` is Phase 2's display block plus one `dependency override:` line per moved dependency, and `--steps` is `radin state steps-init`'s stdin format verbatim, so Phase 3 is a pipe. Writes nothing: an inferred rank or dependency arrives as a flag it validates (unknown id, duplicate, partial rank, self-reference, cycle), never as a `set-priority`/`set-deps` call, so the index stays the human's
- `field <id-or-title> <TASK_FILE|TASK_ID|CATEGORY|PLAN_PATHS|SKILLS|SKILLS_DROPPED|ACCEPTANCE>` — one Execution-prompt placeholder per call, rendered ready to substitute. One value per call rather than a `NAME<TAB>value` listing, because reading one value out of a listing is the model picking from output again. The resolve dies on zero or several matches, so the call's own exit code is the entry-still-exists check; `PLAN_PATHS` and `ACCEPTANCE` exit 1 to say "no plan" / "no criteria", and `SKILLS` is pre-filtered against the four classes a leaf sub-agent cannot run (asks the user, spawns its own agent, launches a workflow, recurses into radin), matched on the leading `/<name>` token only — `SKILLS_DROPPED` names what it removed
- `duplicates` — print `id<TAB><value><TAB><ids>` / `title<TAB><value><TAB><ids>` per duplicated value, exit 1 when there are none. Flags what a hand-edited index left behind; never guesses which copy to drop
- `find <id-or-title>` — locate task, print the same six fields per match (exact id first, then exact title, else case-insensitive substring on title)
- `add <category> <title> [--epic <epic-id>] [--priority <1|2|3|5|8|13|21>] [--depends-on <csv>]` — create task (body on stdin): slugifies title into id (dedupe on collision against the index's `id` fields), writes file, appends one line to index
- `add-plan <id-or-title> <path>` — append `**Plan:**` pointer to task's own file
- `planned` — print the id of every task whose file already carries a `**Plan:**` line; one call answers "which tasks are planned?" for a whole listing, where `meta` per task costs one file read each
- `path <id-or-title>` — print task file's absolute path, resolved by reading matched index line's `file` field and joining it to `backlog/` (what the TUI reads and hands to `$EDITOR`)
- `plan-target <id-or-title> [<sub-slug>]` — the one call `radin-plan` opens on: `id`/`title`/`task_file`/`plan_file` lines, plus one `plan<TAB><path>` line per pointer the entry already carries. It exists because `find`'s four outcomes (one match, several, none, already planned) were a route the skill computed by counting lines and then calling `meta`; they are exit codes 0/2/1/3 here, and exit 2's candidates go to stderr so a resolved record is never confused with a candidate list. `plan_file` is also the one place the `plans/<id>.md` convention lives in code — `add-plan` keeps its required path argument, because the skill has to write the file before it can point at it
- `set-category <id-or-title> <category>` / `retitle <id-or-title> <title>` — rewrite that one index line, id and task file untouched (id stays stable for the task's lifetime, so a retitle can't orphan a `depends_on` or a plan pointer)
- `set-priority <id-or-title> <1|2|3|5|8|13|21|--none>` / `set-deps <id-or-title> <csv-of-ids|--none>` — store the human's ranking and ordering on the index line; `set-deps` refuses an unknown id, a self-reference and a cycle, because an unresolvable dependency stalls `radin state deps-check` instead of failing it
- `remove <id-or-title>` — delete task's file + index line (exact single match required); drops the epic directory too when that was its last child, so `epics` never reports a husk, and prunes the removed id from every other entry's `depends_on`
- `epics` — print every epic id, one per line; a directory listing, because an epic index file would be a second store to keep in sync
- `epic-add <epic-id>` — create the directory and its `DESCRIPTION.md` (body from stdin when piped)
- `epic-show <epic-id>` — print the epic's `DESCRIPTION.md` verbatim (nothing, exit 0, when it is empty)
- `epic-move <id-or-title> <epic-id|--none>` — move the task file and rewrite its `file` field; `--none` returns it to the flat `tasks/` level
- `epic-remove <epic-id>` — refuse while child tasks remain (exit non-zero, delete nothing): the operator moves them out first

`radin scope` (`lib/radin-scope.sh`) is the same offload for `radin-review`'s one input. It resolves a commit, a PR, a directory, the no-argument branch diff, or a range (`last commit`, `last <n> commits`, `<rev>..<rev>`) into `type`/`scope`/`command`/`passes` lines; `passes` names the ponytail skill(s) that scope type calls for, because mapping a type to a pass was the last thing the skill computed from this script's own output. `--in-scope` reads `path:line` citations on stdin and prints `in`/`out` per citation plus a final `dropped<TAB><n>`, which is the out-of-scope drop the skill used to do by eye against the diff. A `since <date>` argument resolves too: the phrase goes to git's approxidate, and the `since` prefix is what keeps a garbage argument — which approxidate also accepts — out of that branch. Format in [domain models](domain-models.md#review-scope-output-radin-scope).

Point: offloading. Id assignment, task lookup, plan-pointer insertion, the execution order and its dependency fix, the ranking gate, prompt-field rendering, the duplicate scan — deterministic ops model used to re-derive from prose rules every run. `lib/radin-prioritization.md` is left with the two things that are not computations: how to rank the unset-priority group, and when one entry's body implies a dependency on another's. CLI does them exact; agents/skills supply only judgment (what to log, how to classify, what to plan). Task's file path always read back from its index line's `file` field, never composed by a caller and never computed from stored line number — nothing here goes stale as backlog shape changes.

`install.sh` copies `lib/radin-namespace.sh`, `lib/radin-backlog.sh`, `lib/radin-state.sh` to `~/.claude/.radin/lib/`, and `bin/radin` — a dispatcher mapping `radin <backlog|tui|state|scope|hooks|repair|update|doctor|uninstall>` to those scripts — to `~/.claude/.radin/bin/`, plus a `~/.local/bin/radin` symlink (an existing non-radin file there is named and left alone, and skills then get the full dispatcher path). `hooks` and `repair` are umbrella verbs over `lib/radin-cbm-hooks.sh` and `lib/radin-cbm-config.sh repair` — the caller names no companion, even though codebase-memory-mcp is the only one either backs today. Consumer install never has this repo's `lib/` directly, so the scripts dist like any other radin file.

Inside script:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
[ -n "$REPO_ROOT" ] || REPO_ROOT="$PWD"
NAMESPACE_DIR="$REPO_ROOT/.claude/.radin"
```

Creates `state/`, `plans/`, `reviews/`, `backlog/tasks/` under `$NAMESPACE_DIR`, then prints four vars with `printf %q` — output stays source-able even when repo path has spaces.

`radin-execute`'s own state files (`BACKLOG_STEPS.json`, `completed.json`) get same treatment as backlog. Sibling CLI, `lib/radin-state.sh`, only way agent mutates either file — never hand-written JSON edit in agent's own prose.

```bash
radin state <steps-init|next-pending|task-next|start|stuck|triage|recover|recover-reject|set-status|remove|deps-check|completed-add|completed-get|completed-list|task-done|task-fail|task-diagnosis|dirty-recover|report|task-dir|prepare|dirty-check|stash|session-set|session-get|journal-tail>
```

- `start <steps-file> <id>` — claim task before dispatch: `status` `in_progress`, `attempts` +1. Exits 2 having marked entry `blocked` once `attempts` passes `MAX_ATTEMPTS` (3), so crash loop can't burn tokens forever
- `task-next <namespace-dir>` — the whole picker in one call: lowest-order `pending` entry, dependency gate, and the block-and-skip route for one whose dependency is unresolved. Prints the `blocked` lines it wrote, then `id`/`order`/`dep` for the task to run. Exit 1 when nothing is left, so orchestrator filters, sorts and joins nothing
- `stuck <steps-file>` — list `in_progress` entries: tasks dispatched by run that died before terminal status. Recovery entry point
- `triage <namespace-dir> <id>` — facts about what dead sub-agent left: `attempts`, `completed` hash, `worktree`, `branch`, `branch_commit` lines, `dirty_files` count. Prints facts, decides nothing — agent routes on them (see `radin-execute` Phase 1 step 3). Worktree path and branch name derived from task id, never recorded: execution prompt pins them to `../<repo>-<id>` / `radin/<id>`
- `recover <namespace-dir> <id>` — act on `triage`'s facts: finish the bookkeeping when a hash is already recorded, return a clean tree to `pending`, stash a dirty one first. Exit 3 prints the commits a dead sub-agent left on `radin/<id>` — the one branch no verb can settle, because only the model can say whether they satisfy the task. It answers with `task-done` or `recover-reject`
- `recover-reject <namespace-dir> <id>` — those commits do not satisfy the task: entry `blocked`, note naming branch and worktree to inspect
- `set-status <steps-file> <id> <pending|in_progress|failed|blocked> [note]` — rewrite one entry's `status`/`note` in place, `order`/`depends_on`/`attempts`/`debugged` untouched
- `remove <steps-file> <id>` — delete one completed entry's line
- `completed-add <completed-file> <id> <hash> [title]` — append completed task's commit, create file if absent. Title stored because completion deletes backlog entry, so nothing else can name task in final report
- `completed-get <completed-file> <id>` — print completed task's commit hash (exit 1 if not recorded), for later task's `depends_on` check
- `completed-list <completed-file>` — print `id<TAB>commit` per completion in file order (exit 1 when nothing is recorded), for the TUI's Done view: completion deletes the backlog entry, so this file is the only record left
- `task-done <namespace-dir> <id> <hash>` — record success, drop backlog and steps entries, crash-safe order. Validates hash first: must be commit reachable from `radin/<id>` (or `HEAD`) in the task's tree, else exit 3 and nothing written. Hash comes off a sub-agent's free-text `STATUS:` line, so nothing else checks it
- `task-fail <namespace-dir> <id> <reason>` — the `FAILED` route. First call per task per session flips the entry's `debugged` flag and exits 3, the caller's signal to send the Debug prompt; second call marks entry `failed` with the composed note and prints the finished report line. `--no-status <last line>` never offers the debug pass
- `task-diagnosis <namespace-dir> <id>` — stdin becomes a `**Root cause:**` line on the task file (only place that label is written). Changes no status: the retry's `start` bumps `attempts`, so `MAX_ATTEMPTS` still ends the loop
- `dirty-recover <namespace-dir> <id> <status-word>` — sub-agent left a dirty tree whatever its `STATUS:` said: resolve the tree with `task-dir`, `stash` it, mark the entry `failed` with the recovery commands in the note, print the report line. Exit 1 when the tree is clean, so the caller routes on `STATUS:` instead
- `report <namespace-dir> [<dropped-skill line>...]` — the finished Phase 5 report text: residual-changes check (stash, never commit), this session's commits with their landing lines per `session.json`, every `failed`/`blocked`/`deferred` entry with its note, the session's stashes, one bullet per extra argument. Scoped to this session by `state/baseline.json`, written by `steps-init`
- `task-dir <repo-root> <id>` — print task's worktree (`<repo-root>-<id>`) when it exists, else repo root. Everything checking or parking one task's files (`dirty-check`, `stash`) goes through it: in worktree mode repo root is not tree sub-agent worked in, and checking wrong one reports clean while work sits uncommitted elsewhere
- `prepare <namespace-dir> <id>` — read `session.json`, create or reuse `<repo-root>-<id>` worktree and `radin/<id>` branch exactly as recorded answers require, print single directory execution sub-agent works in. Only place those two answers turn into git commands, so a model can't reinterpret `no` into a worktree it prefers. Fails when nothing recorded yet
- `dirty-check <dir>` — `git status --porcelain`, `.claude/.radin` excluded so radin's own state writes never read as dirty tree. Execution loop calls `dirty-recover`, not this: leaf verb stays for `report`'s residual check and anything asking the bare question
- `session-set`/`session-get <namespace-dir>` — persist and read Phase 0.5's worktree/branch answers, so resumed run reuses them instead of asking again and splitting session between worktrees and checkout. `prepare` consumes them; orchestrator only reads them back for its final summary
- `journal-tail <namespace-dir> [n]` — last n events from append-only `state/journal.jsonl`, written by every mutation above. Lets agent reconstruct what session already did after context compaction. Forensics only, never control flow

Both `BACKLOG_STEPS.json` and `completed.json` JSONL (one compact object per line), same convention as backlog's `index.jsonl` — single-entry edit never risks another line, model never parses/rewrites bracketed JSON array by hand.

`radin-execute` alone reads `lib/radin-prioritization.md`, via the `RADIN_LIB` token ([resolved at install](#install-time-substitution)), at Phase 1 step 4 and only when `backlog order --rank-needed` exits 0. It holds two things and nothing else: how to rank the unset-priority group, and the bounded dependency inference. Backlog format is `docs/domain-models.md`'s, verb behaviour is the CLI usage comments', so neither is restated there. `radin-plan` reads it not at all — scoped to one entry, nothing to prioritize.

`radin-execute` alone reads six on-demand files, none of them inline in `SKILL.md`, because the skill body sits in the user's own context for the rest of the session. Each one be cold path — trigger fire, file get read, otherwise never:

- `lib/radin-execute-prompts.md` — the four verbatim sub-agent prompts (planning, execution, debug, fact-finding), read at the first Step 4a that dispatches one. A session that stops at Phase 2 (common first turn) never reaches Phase 4, so never loads them.
- `lib/radin-execute-recovery.md` — `triage` routing for tasks a dead session left `in_progress`, read only when `radin-state.sh stuck` exits 0. Most runs never load it.
- `lib/radin-execute-reporting.md` — the two things `state report` cannot do: dropped-skill bullets it must be handed, and the duplicate id/title scan. Read at Phase 5.
- `lib/radin-execute-clarify.md` — `BLOCKED (FACT)`/`(DECISION)` routing, fact-finder handoff, `backlog append` labels, read when a sub-agent block. Run where nothing block never load it.
- `lib/radin-execute-session.md` — how to ask and persist Phase 0.5's worktree/branch answers, read only when `session-get` exit 1. First run in repo, nothing after.
- `lib/radin-execute-resume.md` — resume triage, `MAX_ATTEMPTS` exception, state-persistence contract, read only when `BACKLOG_STEPS.json` already exist at startup or compaction ate earlier turns.

## Why every entry point is a skill

radin-execute was an agent (`agents/radin-execute.md`) until it became a skill. Two Claude Code capability limits forced the move, both documented in `docs/technical-constraints.md`:

- `AskUserQuestion` removed from **every** sub-agent, foreground and background alike. Agent's Phase 2 gate asks user to confirm execution order, so as agent it could never actually ask — every run fell back to ending its turn with question and waiting to be re-invoked.
- Sub-agent's prose reaches only calling session, never user. So agent's own report needed re-summarizing by main thread, and every question had to be encoded as `blocked` backlog state instead of asked.

As skill, radin-execute runs in user's own thread: asks directly, gets interrupted, resumes from disk. Sub-agents stay, one layer down, as leaf workers — that's where context isolation earns its keep (planning's codebase exploration, execution's edits, review's diff read), each returning single `STATUS:` line. Same split SOTA skill collections use: orchestrate in main thread, isolate leaf work.

### Running the backlog in the background

radin ships no agent for this. `claude agents` (agent view) dispatches full Claude Code background sessions — whole tool pool, working `AskUserQuestion`, peek/reply/attach — and `/radin-execute` runs unchanged in one. `/bg` sends the current conversation there. A second `claude` session in another terminal works too.

`radin-plan` is skill, not agent: runs inline in whichever context invokes it. In user's own conversation, judges whether its one scoped entry should split into independent sub-plans, confirms with user directly before splitting, writes plan file + `**Plan:**` pointer per resulting sub-task. Step 4a dispatches one planning sub-agent per task with no `**Plan:**` line yet, invoking `/radin-plan`, in the iteration that then executes that task. Keeps planning's codebase exploration out of orchestrator's context — plan file on disk = handoff to execution sub-agent. That sub-agent runs non-interactively: where skill would ask confirmation, takes non-destructive path (no split, no overwrite, no seam confirmation), genuine ambiguity marks task `blocked` for user instead of guessing.

### Updating the stack

`radin update` (`lib/radin-update.sh`) is the one update path, and it needs no model — same reasoning as `radin doctor` and `radin uninstall`. It reads `~/.claude/.radin/install_root`, which `install.sh` writes every run:

- source has a `.git` dir (dev clone): `git pull --ff-only`, refusing outright when `git status --porcelain` prints anything, then `bash "$SRC/install.sh" --update`.
- anything else (tarball install, or an install predating `install_root`): download the newest `install.sh` from `main` and run it with `--update`, since that installer re-resolves the latest release tarball itself.

`--update` implies `--force` and `--yes`, so every companion tool takes its upgrade path and no behaviour question is re-asked. Instead `install.sh` reads its own previous `manifest.json` (`manifest_value`, a `sed` lookup — no JSON parser) for `parallel_execution` and the five `model_<role>` keys, and writes those answers back into the installed files. Models are all-or-nothing: a manifest missing any of the five falls through to the pickers, so a half-read manifest can't mix recorded picks with defaults. No manifest at all (first install with `--update`) means the documented defaults, never a blocking prompt.

Non-destructive by construction: the installer only `cp`s radin's own files, plugins go through `claude plugin update`, brew/pipx installs re-run as upgrades, and the `radin-cbm-config.sh install` step re-brackets upstream's `settings.json` write with a fresh snapshot. `--force` alone still works, and still asks the three questions.

## Code-graph wiring (codebase-memory-mcp)

`codebase-memory-mcp` is radin's code-intelligence companion: an MCP server that indexes a repo into a persistent knowledge graph, so `radin-plan` and execution sub-agents ask the graph (`search_graph`, `trace_path`, `get_code_snippet`, `query_graph`, `detect_changes`) instead of grepping files.

`install.sh` installs the binary with **`--skip-config`**, sets `auto_index true`, then runs `radin-cbm-config.sh install`, which is upstream's own `codebase-memory-mcp install -y`: its skill, three tiered graph agents (Scout/Verify/Auditor), the user-scope MCP entry in `~/.claude.json`, and the `SessionStart`/`SubagentStart`/`PreToolUse` hooks that route Grep/Glob toward the graph. User-scope MCP is why no per-project step is needed afterwards, and `--skip-config` on the binary install only defers that write so radin can bracket it.

`lib/radin-cbm-config.sh` is the bracket. Upstream [#1200](https://github.com/DeusData/codebase-memory-mcp/issues/1200) — open, maintainer-confirmed, unfixed through v0.10.8 — replaces the whole `SessionStart` array in `~/.claude/settings.json` rather than merging into it, dropping any hook another tool owns. So the script:

1. copies `settings.json` and `~/.claude.json` into `~/.claude/.radin/backups/<name>.<timestamp>.bak` (copies only; radin never deletes one),
2. runs `codebase-memory-mcp install -y`,
3. restores, per hook event, every snapshot entry that is now missing — pre-existing entries first, upstream's after — plus any dropped top-level `settings.json` key and any dropped `mcpServers` entry,
4. prints one `RESTORED`/`INTACT` line per item and a final line saying whether upstream's hooks and MCP entry actually landed.

Entries are compared deep-equal, so re-running restores nothing and reports `INTACT`. A failed upstream install still gets step 3, because its configuration pass is transactional per client, not per file. `radin repair` runs steps 3-4 alone against the newest snapshot, which is what to use after `codebase-memory-mcp update` reruns the same write. `install.sh` captures that whole trace into `~/.claude/.radin/cbm-config.log` rather than relaying it, and surfaces only one line — success, or the `PARTIAL` case, where upstream failed after configuring Claude Code. Every JSON read and write on this path is the compiled helper `lib/radin-cbm-json.c` (built into `~/.claude/.radin/bin/radin-cbm-json`), so `radin-cbm-config.sh` holds no JSON knowledge of its own: it snapshots with `cp`, stashes with `mv`, runs upstream, and calls the helper three times. A C compiler is therefore required for this path; without one `install.sh` skips upstream's configuration and falls back to the merge-only wiring, on the grounds that running a destructive write with no restore is worse than a smaller install.

`lib/radin-cbm-hooks.sh` (dispatched as `radin hooks <claude-md|mcp|all>`, driven by the `radin-setup-hooks` skill) is the fallback for the no-compiler path, and for anyone who ran `codebase-memory-mcp uninstall` but kept radin. Two writes, merge-only, skipping anything already defined:

- the `codebase-memory-mcp` MCP-tools section in `~/.claude/CLAUDE.md`
- `mcpServers.codebase-memory-mcp` in `<repo-root>/.mcp.json`, pointing at the resolved binary path — written by the same `radin-cbm-json` helper (`ensure-mcp`), so with no compiler only `claude-md` runs and `mcp` prints the entry to paste by hand

A later companion tool that needs wiring extends this script and the `radin-setup-hooks` skill, rather than getting a script of its own.

It writes no `settings.json` hook of radin's own: `auto_index` indexes a project on first connection and the background watcher keeps it current, so a `PostToolUse` reindex would pay for nothing. The graph itself lives in `~/.cache/codebase-memory-mcp/`, outside both `~/.claude` and the consumer's repo.

An MCP tool name must exist in upstream's [MCP
Tools](https://github.com/DeusData/codebase-memory-mcp#mcp-tools) table — a
wrong one costs a failed call plus a fallback in every sub-agent that reads
the prompt. Names appear in two files only:
`lib/radin-execute-prompts.md` (execution, debug, fact-finding) and the
CLAUDE.md section inside `lib/radin-cbm-hooks.sh`. The skills name none:
`radin-plan` points at the companion's own skill for the verbs, and
`radin-review`'s Standards axis invokes `/thermo-nuclear` and the `passes`
skills, which choose their own reading.
Between them they name `index_repository`, `list_projects`, `search_graph`,
`search_code`, `trace_path`, `detect_changes`, `query_graph`,
`get_graph_schema`, `get_code_snippet` and `get_architecture`. Each file names
only the tools its own role uses — the subsets differ on purpose — and every
mention carries the same pointer clause verbatim: a graph hit is a pointer,
read the file before you cite or edit it, never conclude something is absent
from an empty result.

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
    radin-execute-clarify.md
    radin-execute-session.md
    radin-execute-resume.md
    radin-namespace.sh
    radin-prioritization.md
    radin-state.sh
    radin-uninstall.sh
  install.sh
  README.md
```

## The human TUI

`list`'s output format is the TUI's parser contract, and `order`/`field`/`duplicates` added no field to it: the TUI still loads `list --order created` and splits on US exactly as before.

Bare `radin` on a terminal (`lib/radin-tui.c`) is the human's way into the same backlog the
skills drive: a two-pane split — the task tree on the left 40% of the width,
the selected row's detail on the right 60% — and one key per operation (`e`
edit in `$EDITOR`, `v` view in `$PAGER`, `o` execution order in `$PAGER`, `a`
new, `d` delete, `c` next category, `r` retitle, `/` search).

`o` is the only key any of `order`/`field`/`duplicates` earned. It pages
`backlog order --report` verbatim, because `Shift-P` sorts by priority and that
is *not* the order `radin-execute` runs: `order` lays the topological
dependency fix over it, and a human who sets a priority with `p` and a
dependency with `D` can create that conflict with nothing on screen to show it.
The rest stay LLM-facing and unbound: `--rank-needed` names the unset
priorities the blank priority column already shows, `--steps` is `state
steps-init`'s stdin format, `field` renders one Execution-prompt placeholder
from values the row and the detail pane already carry, and `duplicates`
diagnoses a hand edit to `index.jsonl` the TUI cannot make.

The detail pane is where every per-task fact that is not a sort key lives: a
`category` / `id` / `priority` / `planned` block, plus `epic` and `depends`
when the task has them. The list row carries only priority and category,
because those two order it — a `P` flag column spent a whole column of a 40%
pane on a fact nobody sorts by. The pane renders the task body through a
hand-rolled markdown subset:
an ATX heading goes bold with its `#` gone, a `>` quote goes dim and indented,
a bullet is re-marked `•`, and `**` is stripped rather than rendered.
`ctrl-d`/`ctrl-u` scroll that pane half a pane at a time and never move the
tree selection, exactly as `j`/`k` move the selection and never scroll the
pane — there is no focus concept and no `Tab`-to-switch.
Below the metadata block the pane has two views of the selected task, named on
a marker line above the content rule with the active one bright: the task body,
and that task's plan files concatenated under the same `### <path>` heading the
composed document uses. `l` (arrow right) switches to the plan, `h` (arrow
left) back to the body — the key decoder already folds those arrows onto the
two letters. The active view sticks across `j`/`k` so the list can be walked
comparing plans, while the scroll offset restarts at the top on every switch
and every move. A task with no plan reads `(no plan yet -- run /radin-plan)`,
and a pointer whose file will not open `(plan file missing)`. An epic header
row has no plan, so the two keys do nothing there, and the Done view ignores
them. `v` stays the one complete document; the pane is a preview of one part of
it. Its limits are
deliberate: no fenced-code state, so a `#` inside a fence still renders bold.
A rendered line wider than the pane wraps at the build step, not the renderer,
so one buffer entry stays one screen line and the scroll offset needs no
source-to-screen map: the break falls on the last space before the cut, each
continuation indents to its line's content column (a bullet's text column, a
quote's indent, a metadata row's value column) and a single token wider than
the pane is hard-cut and continued. The buffer's 1024-line cap therefore bounds
screen lines, so a very long body stops earlier than its last line — `v` opens
the full composed document in `$PAGER`.
The wrap and the pane's own truncation are by display column, not by byte: a wide CJK or emoji glyph
counts as two and a tab flattens to one space, so a pane row cannot grow past
its pane and wrap into its neighbour's columns.
Under 100 columns the right pane is not drawn at all and the tree takes the
full width; `enter` on a task row then opens the same renderer full-screen,
scrolled by the same two keys and dismissed with `q`/ESC. At 100 columns or
more the pane is already on screen, so `enter` on a task row is a genuine
no-op (on an epic header it always collapses). More keystrokes beat an
unreadable UI, because people read this on a phone.
`e` is the other half of that split and only ever edits: a task row's body, or
an epic header's own `DESCRIPTION.md` — the same path `E` writes at creation,
built in one place so the two keys cannot disagree about where it lives.
The tree is drawn in creation order -- `list --order created`, which is
`index.jsonl` line order because the index is append-only. That is what keeps a
row still: `c`, `p`, `r` and `D` all reload, and none of them can move a task
in the index, so nothing jumps out from under the cursor. The one reorder is
the one the user asks for: `Shift-A`/`Shift-P`/`Shift-C`/`Shift-T` sort by
creation order, priority, category or title (k9s's `Shift-<column initial>`
convention, since k9s is the reference for any later keybinding question), the
active one shows in the header as `sort:created`, and it is session-only -- a
restart is back to `sort:created`, with no state file to hold otherwise.
A `*` in the left margin
marks a row matching the active `/` search, and `n`/`N` walk those matches.
Priority is the leftmost column, then the category, then the tree connector and
the title: the cells lead so their columns line up whether or not the task sits
under an epic, and the connector then indents only the title it marks. A title
too long for the pane wraps onto up to `ROW_MAX_LINES` lines, each indented to
the title column, rather than truncating. Wrapping is a drawing concern only:
`SEL` and `TOP` still index rows, and `row_lines()` plus `clamp_top_wrapped()`
are the only two functions that turn a row count into a screen-line count, so
no key handler learns that a row can be taller than one line. Priority is the
only coloured cell of a task row: `21`/`13` red, `8`/`5` yellow, `3`/`2`/`1` green. The map is absolute
because the scale is bounded, so no unrelated task's number can move this row's
colour; anything off the scale -- unset, or a legacy value stored before the
scale was bounded -- renders plain, and `NO_COLOR` drops the escapes entirely.
Every other colour is structural rather than a value, so nothing can be misread
as a priority: an epic header row is cyan, and the pane divider and the detail's
rule are dim. Reverse video is the one cue `NO_COLOR` keeps, on the header and
footer bars and on the selected row -- without it a bar would not read as chrome.
The panes are separated by a `â` gutter column drawn after both, and the
detail opens with the title, one `category Â· id Â· priority` line and a
full-width rule before the body. The rule is the one line the markdown subset
cannot render, because it needs the pane width: it travels through `DET` as a
one-byte sentinel that `draw_detail()` expands. The footer teaches one short line
of keys and `?` owns the full list, because a footer that spills off an
80-column terminal teaches less than one that fits.

An idle TUI polls, because an agent running `/radin-record` or `/radin-execute`
in another terminal writes the same `index.jsonl`. `readkey_wait()` blocks in
`poll()` for 5 seconds instead of blocking in `read()` forever, and on a timeout
compares `index.jsonl`'s `st_mtime` and `st_size` against the pair `load()`
stamped -- seconds and a size, because `st_mtimespec`/`st_mtim` is the one
`stat` field that needs a platform branch and radin has none. Unchanged means
one `stat` and nothing else: no `backlog list`, no repaint, so the footer
message of the last keypress survives a timeout. Changed means `refresh()`,
which is `load()` plus re-finding the selected row by task id or epic name --
under creation order an external write is an append or a drop, so re-finding by
identity is all it takes for the collapse set, the scroll offset and the active
sort (all globals `load()` never touches) to keep the pane exactly where it was.
Only the main loop waits there, so no poll fires while `$EDITOR` or `$PAGER`
owns the terminal: those run inside a key handler. `RADIN_TUI_POLL_MS` shortens
the interval, which is how the tests avoid sitting one out.

Epic children are drawn as a `tree`-style one-level hierarchy: `├──` on every
child but the last, `└──` on the last, and no connector on an ungrouped task.
The shape is read off the row arrays at draw time -- the row after the last
child is always an epic header or nothing -- so it stays a drawing concern and
no key handler learns about tree shape or the collapse set. An epic header also carries its child count, read
off the task array at draw time like the connectors. `span_at()` pads
and truncates by bytes against an explicit width — explicit because a split
pane works per column rather than against `COLS` — and grows that width by the
text's UTF-8 continuation bytes; a three-byte connector character otherwise
costs three columns of the row. The two-argument `row()` and five-argument
`row_span()` wrappers keep every full-width call site (the Done view, the
pickers, the padding rows) unchanged.

Three rules keep it from becoming a second backlog implementation:

- **It draws and dispatches keys, nothing else.** Every mutation shells out to
  `radin-backlog.sh` (`add`, `remove`, `set-category`, `retitle`, `set-deps`,
  `epic-move`), so the index/task-file contract has exactly one owner. A key
  that needs an operation the CLI lacks means adding a CLI subcommand, not
  writing to `index.jsonl` from the TUI.
- **Raw ANSI only — no ncurses, `tput`, `dialog`, `gum` or `fzf`.** Zero
  dependencies is the same promise as the rest of radin: `termios` for raw mode,
  `TIOCGWINSZ` for the terminal size, `\033[` escapes to draw.
- **C, not bash — one of the two compiled files radin ships** (`lib/radin-cbm-json.c`, the JSON surgery behind `radin repair` and `radin hooks mcp`, is the other). A bash frame cost a fork
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

Four things no radin file may state literally. `install.sh` writes each one
in, and each substitution exits non-zero if its token survives — a file that
ships with the token intact invents its own answer.

| Written as | Resolved to |
| --- | --- |
| `RADIN_CLI <subcommand>` in every `skills/*/SKILL.md` and shipped `lib/*.md` | bare `radin` when the `~/.local/bin` symlink is on PATH, else `"$HOME/.claude/.radin/bin/radin"` (`set_cli`) |
| `RADIN_MODEL_<ROLE>` — `PLANNING`, `EXECUTION`, `DEBUG`, `FACTFIND` in `lib/radin-execute-prompts.md`, `REVIEW` in `skills/radin-execute/SKILL.md` | the install-time pick (`set_role_models`). Defaults sonnet, except fact-finding: haiku, since its prompt demands the evidence and the router can reject a wrong answer |
| `RADIN_LIB/<doc>.md` in `skills/radin-execute/SKILL.md` | `$HOME/.claude/.radin/lib` (`set_lib`). The Read tool takes no `$HOME`, so the literal would leave the model expanding it before every on-demand doc read |
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

The one Debug pass a `FAILED` task gets is enforced by the `debugged` flag on
its steps entry, flipped by `radin state task-fail`, not by a counter the
router holds — a counter cannot survive a resume or a compaction.

The pass that moved earlier instead is `radin-plan`'s Step 4, which reviews the
plan on the same two axes `radin-review` runs over code: Standards against the
repo's rubrics, Spec against the entry the plan came from. It costs two
sub-agents per plan and catches a missing acceptance criterion or a contradicted
`**Decision:**` line while the fix is still one edit to a Markdown file. Its
findings stay in the plan file — a backlog entry about code nobody has written
yet would come back to `radin-execute` as work.

Planning is unconditional for the same reason. Step 4a used to skip the
planning sub-agent for a "single obvious change"; the router cannot size a
task without reading the code, and that read is the cost the leaf-worker split
exists to avoid. A task with no `**Plan:**` pointer always gets a planning
sub-agent, which sizes the task with the codebase in front of it and writes a
three-line plan when three lines is what the task needs.

Planning is deliberately not batched ahead of the loop. A wave that plans
every confirmed task up front writes each plan against a tree the earlier
tasks' commits then change, so a later task executes a plan that no longer
describes the code. Step 4a plans one task at a time, immediately before that
task's execution dispatch, and pays a serial planning sub-agent for it.

A task body may state its own `**Acceptance:**` criteria, which
`radin backlog meta` reports and the execution prompt is handed. A task with
no criteria adds no prompt content: a synthesised criterion would measure the
work against radin's own guess.

Those criteria are also the bar for the one recovery branch no command can
settle: `radin state recover` exiting 3 hands the router commits a dead
sub-agent left behind, and `lib/radin-execute-recovery.md` accepts them only
when they meet every criterion the entry states. An entry stating none is a
`recover-reject` and the user's look, never the router's reconstruction of what
the task wanted.

## Delegation is pinned by a test

`tests/skill-names.bats` pins every `/<name>` written in `skills/**/SKILL.md`
and `lib/*.md` to a skill radin ships or `install.sh` installs, so a rename or
typo fails the suite instead of costing a failed call in every sub-agent. A
new companion needs its plugin prefix in that test's list. Not pinned by it:
the MCP graph tool names and the four-file rule above — those are checked by
review, not by `tests/skill-names.bats`.

## One rule, one file

What a future audit checks prose against, after the 2026-09 dedup pass:

- **Two audiences, one statement each.** Skill/lib prose is read by the router or a human-thread skill; a verbatim fence in `lib/radin-execute-prompts.md` is read only by its sub-agent, which never sees the surrounding narration. A fence copy is a payload, not a duplicate; within one audience there is exactly one statement, and a pointer where a second place needs it.
- **Deterministic behaviour is owned by the code that does it** — the usage comments in `lib/radin-backlog.sh` and `lib/radin-state.sh`. Prose names the verb and its exit codes, never what the verb computes.
- **Formats and schemas are owned by `docs/domain-models.md`.** No installed prose file restates one.
- **Cross-skill rules live in the `<!-- radin:begin -->` block `install.sh` writes into `~/.claude/CLAUDE.md`** (never hand-edit `.claude/.radin/`; never guess on a broad ask). It costs no file read and ships with the skills.
- **Reporting your own actions is not orchestration.** The bar is deriving data from CLI output: filtering it, sorting it, joining it, counting it, subtracting two calls. A skill naming the entries it just added, the plans it just wrote, or the findings it just printed is reporting its own work — it holds those facts because it produced them, not because it parsed them out of stdout. Such a report needs no verb.
- **Non-interactivity is declared by the caller, not the callee.** The dispatching prompt says the sub-agent cannot reach the user; the skill states only the branch defaults a reader could not derive.
