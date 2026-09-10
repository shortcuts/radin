# radin — Agent Reference

> Read this before touch any file in repo.

---

## Project

| Field | Value |
| --- | --- |
| What it is | Claude Code plugin: skills + one opt-in agent + install glue |
| Runtime language | None — bash only |
| Target OS | macOS and Linux |
| Supported architectures | Arch-neutral through Homebrew. Works on macOS's `/opt/homebrew`/`/usr/local` and on Linuxbrew's `/home/linuxbrew/.linuxbrew`. No `uname -m` branching. Branch on `command -v` only where tool itself differs by OS (e.g. `md5` vs `md5sum`). |
| Distribution | Git repo ([github.com/shortcuts/radin](https://github.com/shortcuts/radin), currently private). Install with `curl \| bash install.sh` — downloads latest release tarball, or `main` if no release exists, into `~/.claude/radin`. No `git clone` needed. Hack on radin itself: `git clone` + `./install.sh`. |

radin gives solo dev on small Claude subscription one install for cost-optimized agentic workflow. Ships backlog-driven execution
(`radin-execute`, `radin-plan`, `radin-review`), installs companion
tools (rtk, caveman, code-review-graph, thermo-nuclear, ponytail) —
some unconditional, some only on explicit yes pick.
radin never vendors or forks them.

## Dev loop

This repo source of truth. Any skill iteration must be done in `skills/*/SKILL.md`.

Every entry point is a skill, so it runs in the user's own thread and can
talk to them. Sub-agents exist only as leaf workers, dispatched by a skill,
for work whose context is worth isolating. radin ships no agent — see
"Why radin-execute is a skill" below before you add one.

- **Editing radin's own skills:** edit `skills/*/SKILL.md` directly.
  `thermo-nuclear` one exception — not vendored here at all. `install.sh`
  downloads its `SKILL.md` straight from cursor/plugins at install time,
  same as any other companion tool. radin only vendors what it wrote
  itself.
- **Editing `install.sh`, docs, or repo scaffolding:** edit directly, as
  normal.
- **`install.sh`** installs from this repo into `~/.claude/skills` and
  `~/.claude/.radin/lib`. Only adds or updates files there — one direction,
  repo to consumer.

## Storage contract

All backlog content and execution state live inside target repo itself,
in one canonical directory at repo root:

```
<repo-root>/.claude/.radin/
  backlog/
    index.jsonl                  # backlog index, source of truth: one JSON object per task
    tasks/
      <task-id>.md                # one file per task: description + any **Plan:** lines
  state/
    BACKLOG_STEPS.json          # radin-execute execution plan
    completed.json               # radin-execute completed-task -> commit log
    session.json                 # radin-execute worktree/branch answers
    journal.jsonl                # append-only log of every state transition
    facts/
      <task-id>.md                # long-form evidence for one task, written only when a report won't fit inline
  plans/
    <task-id>.md                # radin-plan output
  reviews/
    <review-name>.md            # radin-review / thermo-nuclear output
```

Outside any git repo, current directory takes repo root's place.
This directory only thing radin ever writes into consumer's repo.
radin never edits consumer's `.gitignore` — committing `.claude/.radin/`
(shared backlog) or ignoring it (private backlog) is consumer's call.

Every one of `skills/radin-execute/SKILL.md`, `skills/radin-plan/SKILL.md`,
`skills/radin-review/SKILL.md`, `skills/radin-record/SKILL.md`, and
`skills/radin-show/SKILL.md` goes through shared backlog CLI
(`lib/radin-backlog.sh`) for namespace resolution and every deterministic
backlog operation (locate, append, remove, plan pointers) — model
never hand-edits `index.jsonl` or task file directly, never
addresses backlog content by line number.
Don't reintroduce monolithic `BACKLOG.md`, a
`~/.claude/.radin/projects/<slug>` namespace, or `.shortcuts/*.json`
assumption into any of these files — those exact schemes this one
replaces.

## Backlog entry schema

`docs/schemas/backlog-entry.schema.json` formal, repo-internal contract
for backlog's structure: `$BACKLOG_INDEX` (`index.jsonl`, one JSON
object per task) plus one file per task under `$BACKLOG_TASKS_DIR`. Each
index line carries `id` (stable slug assigned at creation), `category`
(`feat`/`fix`/`chore`/`refactor` — same vocabulary as
conventional-commit type; no per-entry bracket tag beyond it),
`title`, `file`. Matching task file holds exhaustive
description, plus optional trailing `**Plan:**` line.

Read schema (and matching section of `docs/domain-models.md`) before
adding new category, or before writing new skill that writes to
backlog. Schema reference only — never ships to consumers.
`lib/radin-backlog.sh` (which does ship) enforces structural half (id
slugging/dedup, index-line shape, task-file location); each entry-writing
skill keeps only its body-content guidance inline in own `SKILL.md`.

## Why radin-execute is a skill

`radin-execute` was `agents/radin-execute.md` until two Claude Code
capability limits forced it into `skills/radin-execute/SKILL.md`:

- **`AskUserQuestion` is removed from every sub-agent**, foreground and
  background alike, even when the `tools` field lists it. radin-execute's
  Phase 2 gate must ask the user to confirm the execution order, so as an
  agent it could never satisfy its own gate — every run fell back to ending
  its turn with the question and waiting to be re-invoked.
- **Background sub-agents get no `Agent`/`Task` tool at all.** So there is no
  "run radin-execute in the background and free the main thread" packaging
  either: its whole job is delegation, and a backgrounded run cannot dispatch
  a single sub-agent. To free the main thread, start a second Claude Code
  session and run `/radin-execute` there.

Two claims about background sub-agents are easy to get backwards, and both
are settled in `docs/technical-constraints.md`: they **do** keep `Agent`
(the second filter carves it out; its absence from that filter's list is not
removal), and **nobody** picks foreground or background — fork mode removes
`run_in_background` from the `Agent` tool, so no radin prompt may tell a
model to set it.

To run the backlog out of the way, use `claude agents` (agent view) — radin
installs nothing for it: full background sessions, whole tool pool, working
`AskUserQuestion`, and `/radin-execute` runs unchanged in one. (An earlier
radin shipped an opt-in `radin-execute-background` agent for this; it is
gone, and installers/uninstallers only name or remove the leftover file.) As a skill, radin-execute's body sits in the
user's own context for the rest of the session, so keep `SKILL.md` to the
loop and the gates; anything a run needs only sometimes goes in `lib/` and
gets read on demand (`radin-execute-prompts.md` at Phase 4,
`radin-execute-recovery.md` only when `radin-state.sh stuck` finds something,
`radin-execute-reporting.md` at Phase 5).

## Adding new radin skill

Skim existing one first — `skills/radin-review/SKILL.md` shortest
complete example. Shared conventions below easy to drift from if you
reinvent from scratch.

0. **Make it a skill.** See "Why radin-execute is a skill" above: a
   sub-agent cannot ask the user anything.
1. **Namespace resolution and backlog I/O.** Go through
   `bash "$HOME/.claude/.radin/lib/radin-backlog.sh"` (see
   `docs/architecture.md`'s "Namespace resolution and backlog CLI"
   section): `env` for `REPO_ROOT`/`NAMESPACE_DIR`/`BACKLOG_INDEX`/
   `BACKLOG_TASKS_DIR`, and `find`/`add`/`add-plan`/`remove` for entry
   operations. Don't re-embed path resolution or index/task-file surgery
   inline — CLI single source of truth for both.
2. **Backlog writes.** If new skill appends entries, use CLI's
   `add` and classify into existing category
   (feat/fix/chore/refactor) — don't invent fifth. If shape genuinely
   needs to change, update `lib/radin-backlog.sh`,
   `docs/schemas/backlog-entry.schema.json`, and `docs/domain-models.md` in
   same change.
3. **Docs.** Run doc-maintenance checklist below. `docs/architecture.md`'s
   plugin repo layout and namespace-resolution sentence both need new
   file's name added. README's "Tools you get" table needs new row too —
   drifts silently otherwise, since nothing else forces match to
   `skills/`.
4. **`install.sh`.** New skills need `cp -r` line, or `install.sh` never
   distributes them — skill living only in `skills/` in this repo isn't
   installed anywhere yet. If new skill should be verified by
   `radin-doctor`, also add to `lib/radin-doctor.sh`'s expected-file
   list — not derived automatically from `install.sh`'s cp lines.

## radin-execute session preferences

`skills/radin-execute/SKILL.md` Phase 0.5 asks two questions once per backlog run,
via `AskUserQuestion`: use a git worktree per task (default yes), and create a
branch per task (default no). Answers persist to `state/session.json`
(`radin-state.sh session-set`), so resumed run reuses them instead of asking
again.

No prompt carries the answers, and no model reads them to decide anything.
`radin-state.sh prepare <namespace-dir> <id>` is the only place they become
git commands: each execution sub-agent runs it, gets one path back, and works
there. The two answers are not independent: a worktree cannot share the
checkout's branch, so `worktree: yes` always creates `radin/<task-id>` and the
`branch` answer changes nothing. `branch` decides only what happens under
`worktree: no`. `skills/radin-execute/SKILL.md` Phase 0.5 states this and tells the
skill to say so when it asks. Keep it that way — a model that is handed the two answers eventually
overrides a `no`. `prepare` pins worktree path to `<repo>-<task-id>` and
branch to `radin/<task-id>`; `task-dir` and `triage` derive the same names from
task id to find dead sub-agent's leftovers, so keep all three in sync.

## Sub-agent capability limits

Every sub-agent radin spawns can't reach user in prose, can't call
`AskUserQuestion`, and can't be notified about background task. All three show
up as hang with task uncommitted. Rules and reasoning in
`docs/technical-constraints.md` -- read before you point any radin prompt at
new skill, and check that skill doesn't ask user anything or spawn own agent.
The skill itself is under no such limit: it runs in the user's thread.

## Per-task verification in radin-execute

An execution sub-agent's `STATUS: SUCCESS` is a claim, and radin can check it
before recording it. `skills/radin-execute/SKILL.md` carries one
`<!-- radin:refute -->` marker line in Step 4b; `install.sh` asks (default no,
since it costs one sub-agent per successful task) and its awk swaps that line
for `$REFUTE_ON_RULE` or `$REFUTE_OFF_RULE`. Same contract as the concurrency
marker: the marker stays alone on its line, both rule texts live only in
`install.sh`, and `set_refute` exits non-zero if the marker survives.

The refuter never sees the execution sub-agent's report — only the diff, the
task file, the plan(s), and the checks it reruns itself. That asymmetry is the
whole point: a summary of a diff is where a wrong "done" hides. Correctness
belongs in its `VERDICT:` line; structure and taste go to the `/radin-review`
pass it invokes, which logs its own backlog entries and blocks nothing.

A `STATUS: FAILED` gets the **Debug prompt** instead, once per task per
session: a retry with no new information fails identically and burns an
attempt. It diagnoses read-only, the router appends the cause to the task
file, and Step 4b runs again.

Everything either one learns stays on that one task: a `**Fact:**`,
`**Root cause:**` or `**Rework:**` line in its task file, with the long form
in `state/facts/<task-id>.md`. Don't add a shared notes file, a cross-task
memory, or an `agent-memory` store — a sub-agent's context holds its own task
and nothing else, which is what keeps it cheap and on-scope. (Claude Code's
native `memory:` frontmatter field would need radin's leaf roles to ship as
agent definition files, which the "one agent" rule above rules out.)

## Concurrency variants in radin-execute

`skills/radin-execute/SKILL.md` states no concurrency rule. It carries one
`<!-- radin:concurrency -->` marker line in Core Constraints. `install.sh`
asks at install time and its awk swaps that line for `$SEQUENTIAL_RULE` or
`$PARALLEL_RULE` — both defined in `install.sh`, the only place either text
lives. Keep the marker alone on its line, and edit the rule wording in
`install.sh`, never in the skill file. `set_concurrency` exits non-zero if
the marker survives the swap — a skill that ships with neither variant
invents its own rule.

Sub-agent prompts carry no variant. `lib/radin-execute-prompts.md` states
the flat rule instead (a sub-agent never spawns a sub-agent), so the
install-time answer lives in exactly one file.

The answer covers execution sub-agents only. Planning, refuting, debugging
and fact-finding dispatches write no repo code, so Core Constraints allows
them in parallel unconditionally, and both rule texts in `install.sh` say so.
Don't let either variant grow into a rule about those.

## Sub-agent models in radin-execute

No radin file names a model. Each sub-agent role carries a
`RADIN_MODEL_<ROLE>` token instead — `PLANNING`, `EXECUTION`, `REFUTE`,
`DEBUG`, `FACTFIND` in `lib/radin-execute-prompts.md`, `REVIEW` in
`skills/radin-execute/SKILL.md`. `install.sh` asks per
role (only for roles the install enabled — a declined refuter pass gets no
refuter-model question) and its `set_role_models` sed writes the answers in.
Defaults are sonnet,
except fact-finding: it retrieves a checkable fact and its prompt already
demands the evidence that establishes it, so haiku is enough and the router
can reject a wrong answer.

Don't hardcode a model name back into any of those files, and don't add a role
without a token — `set_role_models` exits non-zero if a token survives, but it
cannot notice a literal that was never a token. New role: add the token, a
`MODEL_<ROLE>` default, a picker, and a `-e` clause in `set_role_models`.

## Constraints

**Never touch anything in `~/.claude` (`~/.config/.claude`) besides what
radin itself added.** `~/.claude/skills` shared directory — consumer's other
skills/tools live there too.
`~/.claude/.radin/lib` radin's own global tool directory (distinct from
per-repo `<repo-root>/.claude/.radin/` backlog namespace — same `.radin`
name, different scope: this one holds shared scripts like
`radin-backlog.sh`, not backlog state). `install.sh` may only `cp`/`cp -r`
radin's own named files (radin's own `skills/<name>/`,
`agents/radin-execute-background.md`, `lib/*` into `~/.claude/.radin/lib/`) and
`mkdir -p`. Never `rm` — a pre-migration `~/.claude/agents/radin-execute.md`,
or a `radin-execute-background.md` the user has since declined, gets a warning
plus the exact `rm` to run, never a deletion. Never wildcard-delete directory. Never overwrite file radin didn't
ship. Call out explicitly on any edit to `install.sh`.

**macOS ships `/bin/bash` 3.2.** Apple froze it before GPLv3 switch.
Since scripts run on both macOS and Linux, every script in this repo
(`install.sh`, any future script) must stay bash-3.2-compatible: no
associative arrays, no `mapfile`, no `${var,,}` case conversion. Call
out explicitly on any script edit — easy to reach for bash-4+ syntax
without noticing on machine with newer bash on `PATH`.

**Arch/OS neutrality.** No `uname -m` branching anywhere. Resolve through
`$(command -v brew)` / `brew shellenv` and let brew/npm/cargo pick right
prefix for machine (macOS ARM/Intel, or Linux via Linuxbrew). Where
command itself differs by OS — e.g. BSD `md5` on macOS vs GNU `md5sum` on
Linux — branch on `command -v <tool>`, never on `uname`.

**Companion-tool installs advisory only.** `install.sh` asks and
delegates; never guarantees rtk/caveman/code-review-graph's own install
succeeds, never installs without explicit yes pick.

**rtk available for both user and sub-agent command execution.** When
installed, both sub-agents and users can wrap commands with `rtk` for
token-saving. Sub-agent prompts include guidance to use `rtk` when available
(`command -v rtk` succeeds); fallback when absent transparent.

## Doc-maintenance policy

Change isn't done until affected docs updated in same commit.

| File | Update when |
| --- | --- |
| `docs/architecture.md` | Storage scheme, namespace resolution, or plugin file layout changes |
| `docs/domain-models.md` | Backlog entry format, plan-file format, or state-JSON schema changes |
| `install.sh` companion-tool table (README) | Companion tool added, removed, or renamed |
| "Tools you get" table (README) | radin-built skill added, removed, or renamed |
| `CHANGELOG.md` | Any user-facing change, on every release |

## Pre-commit checklist

- `make lint` clean (or documented exceptions only)
- `make test` clean
- Docs updated per table above

## Code Style & Testing

→ See `CONTRIBUTING.md`

## Architecture

→ See `docs/architecture.md`

## Domain Models

→ See `docs/domain-models.md`

## Technical Constraints

→ See `docs/technical-constraints.md`
