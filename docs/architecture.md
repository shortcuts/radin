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
  BACKLOG.md                    # backlog, source of truth
  state/
    BACKLOG_STEPS.json          # radin-execute execution plan
  plans/
    <task-id>.md                # radin-plan output, one file per plan
  reviews/
    <review-name>.md            # radin-review / thermo-nuclear output
```

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
bash "$HOME/.claude/radin-lib/radin-backlog.sh" <env|show|find|add|add-plan|remove>
```

- `env` — namespace resolution (delegates to `lib/radin-namespace.sh`, the
  single source of truth for the path logic; prints `REPO_ROOT`,
  `NAMESPACE_DIR`, `BACKLOG_FILE`)
- `show [category]` — print the backlog, or one `##` section
- `list` — print `line_start<TAB>line_end<TAB>title` for every entry
- `find <title>` — locate an entry, print `line_start<TAB>line_end<TAB>title`
  per match (exact title first, else case-insensitive substring)
- `add <category> <title>` — append an entry (body on stdin); creates the
  file and its category section in canonical order
- `add-plan <title> <path>` — insert a `**Plan:**` pointer into an entry
- `remove <title>` — delete an entry (exact single match required)

The point is offloading: entry location, section ordering, span math, and
plan-pointer insertion are deterministic text operations the model used to
re-derive from prose rules on every run. The CLI does them exactly, and the
agents/skills only supply judgment (what to log, how to classify, what to
plan).

`install.sh` copies `lib/radin-namespace.sh` and `lib/radin-backlog.sh` to
`~/.claude/radin-lib/`. A consumer install never has this repo's `lib/`
directly, so both scripts are distributed like any other radin file.

Inside the script:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
[ -n "$REPO_ROOT" ] || REPO_ROOT="$PWD"
NAMESPACE_DIR="$REPO_ROOT/.claude/.radin"
```

It creates `state/`, `plans/`, and `reviews/` under `$NAMESPACE_DIR`, then
prints the three variables with `printf %q` so the output stays source-able
even when the repo path contains spaces.

`radin-execute` and the `radin-plan` skill also share `lib/radin-prioritization.md`
— the single source of truth for backlog parsing rules, task priority
criteria, and the state-file JSON schema. Both read it via
`$HOME/.claude/radin-lib/radin-prioritization.md` — `radin-execute` at the
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
  docs/
  lib/
    radin-backlog.sh
    radin-namespace.sh
    radin-prioritization.md
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
