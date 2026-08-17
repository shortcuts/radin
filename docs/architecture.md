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
  state/
    BACKLOG_STEPS.json          # radin-execute execution plan
    completed.json               # radin-execute completed-task -> commit log
  plans/
    <task-id>.md                # radin-plan output, one file per plan
  reviews/
    <review-name>.md            # radin-review / thermo-nuclear output
```

Split each task into own file, not one monolithic doc: no radin agent/skill addresses backlog content by line number — `**Plan:**` insert into one task's file can't touch any other task's file. `index.jsonl` = JSON Lines — one compact object per line, `{"id":...,"category":...,"title":...,"file":...}` — not single JSON array. Bash 3.2 got no JSON parser, project got no `jq` dep, so one-object-per-line keeps every CLI op a grep/sed one-liner.

Outside any git repo, current directory takes repo root's place.

Replaced earlier `~/.claude/.radin/projects/<repo-slug>/` scheme. That scheme kept target repos untouched, but hashed slug one abstraction too many: agent resolving it (haiku, default) had to trust opaque mapping instead of path it can see. In-repo state removes mapping. Backlog always at `.claude/.radin/` in repo worked on. Commit or gitignore it — consumer's call, radin never touches `.gitignore`. Old `~/.claude/.radin/projects/` data not migrated.

## Namespace resolution and the backlog CLI

Every one of `agents/radin-execute.md`, `skills/radin-plan/SKILL.md`, `skills/radin-review/SKILL.md`, `skills/radin-record/SKILL.md`, `skills/radin-show/SKILL.md` goes through same shared CLI, `lib/radin-backlog.sh`, for every deterministic backlog op:

```bash
bash "$HOME/.claude/.radin/lib/radin-backlog.sh" <env|show|find|add|add-plan|remove>
```

- `env` — namespace resolution (delegates to `lib/radin-namespace.sh`, single source of truth for path logic; prints `REPO_ROOT`, `NAMESPACE_DIR`, `BACKLOG_INDEX`, `BACKLOG_TASKS_DIR`)
- `show [category]` — render backlog as markdown (all tasks, or one category), reconstructed from `index.jsonl` + each task's file
- `list` — print `id<TAB>category<TAB>title<TAB>file` per task
- `find <id-or-title>` — locate task, print `id<TAB>category<TAB>title<TAB>file` per match (exact id first, then exact title, else case-insensitive substring on title)
- `add <category> <title>` — create task (body on stdin): slugifies title into id (dedupe on collision), writes file, appends one line to index
- `add-plan <id-or-title> <path>` — append `**Plan:**` pointer to task's own file
- `remove <id-or-title>` — delete task's file + index line (exact single match required)

Point: offloading. Id assignment, task lookup, plan-pointer insertion — deterministic ops model used to re-derive from prose rules every run. CLI does them exact; agents/skills supply only judgment (what to log, how to classify, what to plan). Task's file path always `$BACKLOG_TASKS_DIR/<id>.md`, never computed from stored line number — nothing here goes stale as backlog shape changes.

`install.sh` copies `lib/radin-namespace.sh`, `lib/radin-backlog.sh`, `lib/radin-state.sh` to `~/.claude/.radin/lib/`. Consumer install never has this repo's `lib/` directly, so all three scripts dist like any other radin file.

Inside script:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
[ -n "$REPO_ROOT" ] || REPO_ROOT="$PWD"
NAMESPACE_DIR="$REPO_ROOT/.claude/.radin"
```

Creates `state/`, `plans/`, `reviews/`, `backlog/tasks/` under `$NAMESPACE_DIR`, then prints four vars with `printf %q` — output stays source-able even when repo path has spaces.

`radin-execute`'s own state files (`BACKLOG_STEPS.json`, `completed.json`) get same treatment as backlog. Sibling CLI, `lib/radin-state.sh`, only way agent mutates either file — never hand-written JSON edit in agent's own prose.

```bash
bash "$HOME/.claude/.radin/lib/radin-state.sh" <set-status|remove|completed-add|completed-get|dirty-check>
```

- `set-status <steps-file> <id> <pending|failed|blocked> [note]` — rewrite one entry's `status`/`note` in place, `order`/`depends_on` untouched
- `remove <steps-file> <id>` — delete one completed entry's line
- `completed-add <completed-file> <id> <hash>` — append completed task's commit, create file if absent
- `completed-get <completed-file> <id>` — print completed task's commit hash (exit 1 if not recorded), for later task's `depends_on` check
- `dirty-check <repo-root>` — `git status --porcelain`, `.claude/.radin` excluded so radin's own state writes never read as dirty tree

Both `BACKLOG_STEPS.json` and `completed.json` JSONL (one compact object per line), same convention as backlog's `index.jsonl` — single-entry edit never risks another line, model never parses/rewrites bracketed JSON array by hand.

`radin-execute` and `radin-plan` skill also share `lib/radin-prioritization.md`, single source of truth for backlog parsing rules, task priority criteria, state-file JSON schema. Both read via `$HOME/.claude/.radin/lib/radin-prioritization.md` — `radin-execute` at start of Phase 1, `radin-plan` at start of its Step 2 — instead of embedding own copy. `radin-execute` uses all of it, prioritize/order whole backlog. `radin-plan` uses only parsing section: scoped to single entry caller points at, not whole backlog, so nothing to prioritize, no state file of own.

`radin-execute` alone reads `lib/radin-execute-prompts.md`, the two verbatim sub-agent prompts (planning for Step 4a, execution for Step 4b). It reads them at start of Phase 4, not inline in agent file. A session that stops at Phase 2 (common first turn) never reaches Phase 4, so never loads them — keeps that turn's context lean.

`radin-plan` is skill, not agent: runs inline in whichever context invokes it. In user's own conversation, judges whether its one scoped entry should split into independent sub-plans, confirms with user directly before splitting, writes plan file + `**Plan:**` pointer per resulting sub-task. For any task reaching Phase 3 with no `**Plan:**` line yet, `radin-execute` delegates planning to dedicated planning sub-agent invoking `/radin-plan`. Keeps planning's codebase exploration out of orchestrator's context — plan file on disk = handoff to execution sub-agent. That sub-agent runs non-interactively: where skill would ask confirmation, takes non-destructive path (no split, no overwrite), genuine ambiguity marks task `blocked` for user instead of guessing.

To update radin itself, re-run `install.sh` — plain `curl | bash`, or `./install.sh` from dev clone. Always re-downloads/re-copies `agents/*.md` and `skills/*/`, overwrites what's in `~/.claude/`. Pass `--force` to also re-prompt on companion tools `install.sh` would otherwise skip since already on system.

## Install manifest

`install.sh` writes `~/.claude/.radin/manifest.json` every run: generated snapshot of what installed. Records `version` (release tag, or `dev` for local git clone), `installed_at` (UTC timestamp), `agents`/`skills`/`lib` file lists copied, `parallel_execution` (whether install allowed `radin-execute` to fan out sub-agents), `companion_tools` object recording whether each of rtk, code-review-graph, headroom, caveman, ponytail reachable on this machine after confirmation prompts.

Snapshot for external tooling to read, not live source of truth. `radin-doctor.sh` and `radin-uninstall.sh` each keep own independent file list, check filesystem direct, rather than trust manifest. Corrupted or stale manifest must never make either report false "OK" or delete wrong thing.

## Plugin repo layout

```
radin/
  .claude-plugin/
    plugin.json
  agents/
    radin-execute.md
  skills/
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
  lib/
    radin-backlog.sh
    radin-doctor.sh
    radin-execute-prompts.md
    radin-namespace.sh
    radin-prioritization.md
    radin-state.sh
    radin-uninstall.sh
  install.sh
  README.md
```

## Authoring vs. distribution

This repo source of truth. `agents/*.md`, `skills/*/SKILL.md` authored/edited direct here — no external fork, no sync step. `install.sh` dist them one-directional into `~/.claude/agents`, `~/.claude/skills`. `thermo-nuclear` not part of this repo at all: `install.sh` downloads its `SKILL.md` straight from cursor/plugins at install time.
