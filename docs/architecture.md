# Architecture

## What radin is

A Claude Code plugin — agents, skills, and install glue — distributed as a
git repo and installed with `install.sh`. No runtime language, bash only,
macOS and Linux (through Homebrew/Linuxbrew — see `AGENTS.md`'s
arch-neutrality rule).

## Storage model

All radin state — backlog content and execution state — lives inside the
target repo, in one directory at the repo root:

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

Splitting each task into its own file (rather than one monolithic
markdown document) means no radin agent/skill ever addresses backlog
content by line number: a `**Plan:**` insertion into one task's file
cannot affect any other task's file. `index.jsonl` is JSON Lines (one
compact object per line: `{"id":...,"category":...,"title":...,"file":...}`)
rather than a single JSON array, since bash 3.2 has no JSON parser and the
project has no `jq` dependency — one-object-per-line keeps every CLI
operation a grep/sed one-liner.

Outside any git repo, the current directory takes the repo root's place.

This replaced an earlier `~/.claude/.radin/projects/<repo-slug>/` scheme.
That kept target repos untouched, but the hashed slug was one abstraction
too many: the agent resolving it (haiku, by default) had to trust an opaque
mapping instead of a path it can see. In-repo state removes the mapping —
the backlog is always at `.claude/.radin/` in the repo being worked on, and
whether to commit or gitignore it is the consumer's call (radin never edits
`.gitignore`). Old `~/.claude/.radin/projects/` data is not migrated.

## Namespace resolution and the backlog CLI

Every one of `agents/radin-execute.md`, `skills/radin-plan/SKILL.md`,
`skills/radin-review/SKILL.md`, `skills/radin-record/SKILL.md`, and
`skills/radin-show/SKILL.md` goes through the same shared CLI,
`lib/radin-backlog.sh`, for every deterministic backlog operation:

```bash
bash "$HOME/.claude/.radin/lib/radin-backlog.sh" <env|show|find|add|add-plan|remove>
```

- `env` — namespace resolution (delegates to `lib/radin-namespace.sh`, the
  single source of truth for the path logic; prints `REPO_ROOT`,
  `NAMESPACE_DIR`, `BACKLOG_INDEX`, `BACKLOG_TASKS_DIR`)
- `show [category]` — render the backlog as markdown (all tasks, or one
  category), reconstructed from `index.jsonl` + each task's file
- `list` — print `id<TAB>category<TAB>title<TAB>file` for every task
- `find <id-or-title>` — locate a task, print `id<TAB>category<TAB>title<TAB>file`
  per match (exact id first, then exact title, else case-insensitive
  substring on title)
- `add <category> <title>` — create a task (body on stdin): slugifies the
  title into an id (deduped on collision), writes its file, appends one
  line to the index
- `add-plan <id-or-title> <path>` — append a `**Plan:**` pointer to the
  task's own file
- `remove <id-or-title>` — delete a task's file and its index line (exact
  single match required)

The point is offloading: id assignment, task lookup, and plan-pointer
insertion are deterministic operations the model used to re-derive from
prose rules on every run. The CLI does them exactly, and the agents/skills
only supply judgment (what to log, how to classify, what to plan). A task's
file path is always `$BACKLOG_TASKS_DIR/<id>.md` — never computed from a
stored line number, so nothing here goes stale as the backlog changes
shape around it.

`install.sh` copies `lib/radin-namespace.sh`, `lib/radin-backlog.sh`, and
`lib/radin-state.sh` to `~/.claude/.radin/lib/`. A consumer install never
has this repo's `lib/` directly, so all three scripts are distributed like
any other radin file.

Inside the script:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
[ -n "$REPO_ROOT" ] || REPO_ROOT="$PWD"
NAMESPACE_DIR="$REPO_ROOT/.claude/.radin"
```

It creates `state/`, `plans/`, `reviews/`, and `backlog/tasks/` under
`$NAMESPACE_DIR`, then prints the four variables with `printf %q` so the
output stays source-able even when the repo path contains spaces.

`radin-execute`'s own state files (`BACKLOG_STEPS.json`, `completed.json`)
get the same treatment as the backlog: a sibling CLI, `lib/radin-state.sh`,
is the only way the agent mutates either file — never a hand-written JSON
edit in the agent's own prose.

```bash
bash "$HOME/.claude/.radin/lib/radin-state.sh" <set-status|remove|completed-add|completed-get|dirty-check>
```

- `set-status <steps-file> <id> <pending|failed|blocked> [note]` — rewrite
  one entry's `status`/`note` in place, `order`/`depends_on` untouched
- `remove <steps-file> <id>` — delete one completed entry's line
- `completed-add <completed-file> <id> <hash>` — append a completed task's
  commit, creating the file if absent
- `completed-get <completed-file> <id>` — print a completed task's commit
  hash (exit 1 if not recorded), for a later task's `depends_on` check
- `dirty-check <repo-root>` — `git status --porcelain`, with `.claude/.radin`
  excluded so radin's own state writes never read as a dirty tree

Both `BACKLOG_STEPS.json` and `completed.json` are JSONL (one compact object
per line), the same convention as the backlog's `index.jsonl` — a
single-entry edit never risks another line, and the model never needs to
parse or rewrite a bracketed JSON array by hand.

`radin-execute` and the `radin-plan` skill also share `lib/radin-prioritization.md`
— the single source of truth for backlog parsing rules, task priority
criteria, and the state-file JSON schema. Both read it via
`$HOME/.claude/.radin/lib/radin-prioritization.md` — `radin-execute` at the
start of Phase 1, `radin-plan` at the start of its Step 2 — instead of
embedding their own copy. `radin-execute` uses all of it, to prioritize and
order the whole backlog. `radin-plan` only uses the parsing section — it's
scoped to a single entry the caller points it at, not the whole backlog, so
it has nothing to prioritize and no state file of its own.

`radin-plan` is a skill, not an agent: it runs inline in whichever context
invokes it. In a user's own conversation it judges whether its one scoped
entry should split into independent sub-plans, confirming with the user
directly before splitting, then writes a plan file and `**Plan:**` pointer
per resulting sub-task. `radin-execute` delegates planning to a dedicated
planning sub-agent that invokes `/radin-plan`, for any task that reaches
Phase 3 with no `**Plan:**` line yet — planning's codebase exploration
stays out of the orchestrator's context, and the plan file on disk is the
handoff to the execution sub-agent. That sub-agent runs non-interactively:
where the skill would ask for confirmation it takes the non-destructive
path (no split, no overwrite), and genuine ambiguity marks the task
`blocked` for the user instead of guessing.

To update radin itself, re-run `install.sh` — plain `curl | bash`, or
`./install.sh` from a dev clone. It always re-downloads or re-copies
`agents/*.md` and `skills/*/`, overwriting what's in `~/.claude/`. Pass
`--force` to also re-prompt on companion tools `install.sh` would otherwise
skip because they're already on the system.

## Install manifest

`install.sh` writes `~/.claude/.radin/manifest.json` on every run: a
generated snapshot of what it installed. It records `version` (the release
tag, or `dev` for a local git clone), `installed_at` (UTC timestamp), the
`agents`/`skills`/`lib` file lists it copied, and a `companion_tools`
object recording whether each of rtk, code-review-graph, headroom,
caveman, i-have-adhd, and ponytail is reachable on this machine after the
confirmation prompts.

It's a snapshot for external tooling to read, not a live source of truth.
`radin-doctor.sh` and `radin-uninstall.sh` each keep their own independent
file list and check the filesystem directly, rather than trusting the
manifest — a corrupted or stale manifest must never make either of them
report a false "OK" or delete the wrong thing.

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
    radin-namespace.sh
    radin-prioritization.md
    radin-state.sh
    radin-uninstall.sh
  install.sh
  README.md
```

## Authoring vs. distribution

This repo is the source of truth. `agents/*.md` and `skills/*/SKILL.md` are
authored and edited directly here — no external fork, no sync step.
`install.sh` distributes them one-directionally into `~/.claude/agents` and
`~/.claude/skills`. `thermo-nuclear` isn't part of this repo at all:
`install.sh` downloads its `SKILL.md` straight from cursor/plugins at
install time.
