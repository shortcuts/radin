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

radin gives solo dev on small Claude subscription one install for
cost-optimized agentic workflow. Ships backlog-driven execution
(`radin-execute`, `radin-plan`, `radin-review`) and installs every companion
tool it delegates to (rtk, caveman, ponytail, codebase-memory-mcp, headroom,
thermo-nuclear, mattpocock-skills). The stack is opinionated: no per-tool
question, because every skill here delegates to tools it assumes exist.
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
Backlog lives only in `<repo-root>/.claude/.radin/`: no monolithic
`BACKLOG.md`, no `~/.claude`-side per-project namespace, no `.shortcuts/*.json`
assumption in any of these files.

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

`radin-execute` lives in `skills/radin-execute/SKILL.md` because two Claude
Code capability limits rule out shipping it as an agent:

- **`AskUserQuestion` is removed from every sub-agent**, foreground and
  background alike, even when the `tools` field lists it. radin-execute's
  Phase 2 gate must ask the user to confirm the execution order, which an
  agent can never do.
- **Nobody picks foreground or background.** Fork mode removes
  `run_in_background` from the `Agent` tool, so no radin prompt may tell a
  model to set it. Background sub-agents do keep `Agent` itself — see
  `docs/technical-constraints.md`, where both tool-filter rules are settled.

To run the backlog out of the way, use `claude agents` (agent view) — radin
installs nothing for it: full background sessions, whole tool pool, working
`AskUserQuestion`, and `/radin-execute` runs unchanged in one. As a skill, radin-execute's body sits in the
user's own context for the rest of the session, so keep `SKILL.md` to the
loop and the gates; anything a run needs only sometimes goes in `lib/` and
gets read on demand (`radin-execute-prompts.md` at Phase 4,
`radin-execute-recovery.md` only when `radin state stuck` finds something,
`radin-execute-reporting.md` at Phase 5).

## Adding new radin skill

Skim existing one first — `skills/radin-review/SKILL.md` shortest
complete example. Shared conventions below easy to drift from if you
reinvent from scratch.

0. **Make it a skill.** See "Why radin-execute is a skill" above: a
   sub-agent cannot ask the user anything.
1. **Namespace resolution and backlog I/O.** Go through
   the `radin backlog` CLI (dispatcher `bin/radin`; see
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

## What radin delegates, and why it never reimplements it

Every companion tool installs, so a radin skill may assume one is there and
delegate to it. The rule is one owner per job: if a shipped tool already does
the job, radin names it instead of writing its own version.

| Job | Owner | Named in |
| --- | --- | --- |
| Interview the user until a decision is settled | `/mattpocock-skills:grilling` | `radin-record`, `radin-plan`, `radin-review` |
| Check third-party API/library behavior | `/mattpocock-skills:research` | `radin-plan` (interactive only) |
| Place a module boundary / shape an interface | `/mattpocock-skills:codebase-design` | `radin-plan` |
| Diagnose a failed attempt | `/mattpocock-skills:diagnosing-bugs` | Debug prompt |
| Keep the change minimal | `/ponytail:ponytail` | `radin-plan`, `radin-execute`, Execution prompt |
| Over-engineering review | `/ponytail:ponytail-review`, `/ponytail:ponytail-audit` | `radin-plan`, `radin-review` |
| Deliberate-shortcut ledger | `/ponytail:ponytail-debt` | `radin-review` (directory scope), `radin-stats` |
| Maintainability review | `/thermo-nuclear` | `radin-plan`, `radin-review` |
| Per-category implementation discipline | `/caveman:surgical-patch` (fix), `/caveman:safe-refactor` (refactor), `/caveman:lean-build` (feat) | Execution prompt |
| Commit message | `/caveman:caveman-commit` | Execution prompt |
| Code structure questions | codebase-memory-mcp's MCP tools | see the code-graph section below |
| Command output compression | `rtk` | every prompt that runs a command |
| Structural search/diff/repo shape | `headroom sg` / `diff` / `loc` | Execution prompt, `radin-plan` |
| Measured savings | `caveman-stats`, `rtk gain`, `headroom savings`, `ponytail-gain` | `radin-stats` |

Two constraints bound this. A sub-agent cannot be sent into a skill that asks
the user or spawns its own agent (see "Sub-agent capability limits"), so
every prompt that names one of these carries the escape clause: drop the
skill, never wait on it. And each delegation is a `command -v` or
availability check away from being skipped, because a companion install is
advisory and may have failed.

Adding a delegation: put the tool name in exactly one of the files above, and
add the row here. A second copy of the same delegation drifts silently.

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

There is none, deliberately. A `STATUS: SUCCESS` goes straight to the
bookkeeping, and the session's one verification pass is `/radin-review` at
Phase 6. A per-task refuter sub-agent used to run here; it cost one extra
sub-agent per successful task and slowed every run for findings the Phase 6
pass finds anyway. Don't reintroduce one, and don't have the router re-read
the diff instead — that read is the cost the single end-of-session pass
exists to avoid.

A task body may state its own `**Acceptance:**` criteria, which
`radin backlog meta` reports and the execution prompt is handed, so the
sub-agent implements against a stated outcome instead of prose. A task with no
criteria adds no prompt content at all — a synthesised criterion would measure
the work against radin's own guess.

A `STATUS: FAILED` gets the **Debug prompt** instead, once per task per
session: a retry with no new information fails identically and burns an
attempt. It diagnoses read-only, the router appends the cause to the task
file, and Step 4b runs again.

Everything either one learns stays on that one task: a `**Fact:**` or
`**Root cause:**` line in its task file, with the long form
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

The answer covers execution sub-agents only. Planning, debugging
and fact-finding dispatches write no repo code, so Core Constraints allows
them in parallel unconditionally, and both rule texts in `install.sh` say so.
Don't let either variant grow into a rule about those.

## The radin CLI and its token

Skills never hardcode how the CLI is invoked. Every CLI call in
`skills/*/SKILL.md` and the shipped `lib/*.md` prompt files is written as
`RADIN_CLI <backlog|state|scope|cbm-hooks|cbm-config|update|doctor|uninstall> ...`; `install.sh`'s
`set_cli` resolves the token to bare `radin` (when the `~/.local/bin` symlink
exists and that directory is on PATH) or to the full dispatcher path
(`"$HOME/.claude/.radin/bin/radin"`) otherwise. Same contract as the model
tokens: don't write either literal form into a skill, and `set_cli` exits
non-zero if a token survives. The dispatcher itself is `bin/radin`.

## Install, update, uninstall belong to the CLI

Anything deterministic enough to need no model is a CLI subcommand, never a
skill's job: `radin doctor`, `radin uninstall`, `radin cbm-config`, and
`radin update`. A skill exists on top of one only as the slash-command
surface, and it delegates instead of reimplementing.

`radin update` (`lib/radin-update.sh`) refreshes radin plus every companion
tool in one run. It reads `~/.claude/.radin/install_root` (written by
`install.sh` each run), `git pull --ff-only`s a dev clone — refusing a dirty
tree — or downloads the newest `install.sh` from `main`, then re-runs it with
`--update`.

`--update` implies `--force` and `--yes`, and `install.sh` reads its own
previous `manifest.json` for `parallel_execution` and the five
`model_<role>` keys, so an update keeps the recorded answers rather than
re-asking or silently resetting to defaults. The manifest is the only state
that survives, so any new install-time question must be recorded there too —
otherwise the next update resets it. Models are read all-or-nothing: a
manifest missing one key falls through to the pickers.

## The human TUI

`radin tui` (`lib/radin-tui.sh`) is the human-facing backlog browser: an epic
tree whose headers collapse, a composed detail pane for the selected row, a
`Tab` Done view, `e` edit in `$EDITOR`, `n` new, `d` delete, `c` category, `r`
retitle, `p` priority, `D` deps, `m` epic move, `E` epic create, `/` filter.
Not a skill, and no agent invokes it — a TUI needs a
terminal and a human at it, and every agent-facing path is already a CLI
subcommand.

Two rules:

- **The TUI draws and dispatches keys, nothing else** — reads as well as
  mutations. Mutations shell out to `radin-backlog.sh` (`add`, `remove`,
  `set-category`, `retitle`, `set-priority`, `set-deps`, `epic-move`,
  `epic-add`, `path`); every read goes through `list`, `epics`,
  `planned`, `epic-show`, `meta`, `find`, `path` or
  `radin state completed-list`. A view that needs data no subcommand exposes
  means adding a CLI subcommand — never parsing `index.jsonl` or
  `completed.json` from the TUI.
- **The collapse set is a space-delimited string**, because bash 3.2 has no
  associative arrays, and navigation skips a collapsed epic's children because
  `build_rows` never emits them — no key handler knows about collapse.
- **A failed mutation sets `MSG` and does not reload.** The footer shows the
  CLI's own die message and `SEL`/`TOP`/`COLLAPSED` keep their values, so a
  rejected `set-deps` cycle is visibly a rejection rather than a no-op.
- **One `pick` helper serves every chooser** (`multi` for a set, `single` for a
  choice), drawn with `row` and driven by `readkey`. Candidates are passed as
  an argument, never on stdin — `readkey` owns fd 0.
- **Colour is one relative band per row, computed in `load`.** `PRIO_MIN`/
  `PRIO_MAX` come from the set priorities loaded; `prio_colour` splits that
  range in three (`\033[31m`/`[33m`/`[32m`, basic 8-colour so every terminal
  renders it) and returns nothing for an unset priority, for `NO_COLOR`, or for
  a zero-width range, which renders yellow instead of dividing by zero. Bands
  are deliberately relative, so an unrelated task's number changes this one's
  colour — a fixed palette cannot cover an unbounded integer. Category stays a
  plain-text column; priority is the only thing that carries colour.
- **Raw ANSI only.** `stty` for raw mode and terminal size, `\033[` escapes to
  draw, `read -rsn1` for keys. No `tput`, `dialog`, `whiptail`, `gum` or
  `fzf`, and no vendored bash TUI library (`bash-tui-toolkit` solves this the
  same way; borrow the technique, don't copy the bundle). Zero dependencies is
  the same promise as the rest of radin.

Every key that mutates something is covered in `tests/tui.bats`, driven on a
real pty by `tests/helpers/pty-run.py` — assert on the backlog store, not on
the drawn frame, so a layout change doesn't break the suite.

## Sub-agent models in radin-execute

No radin file names a model. Each sub-agent role carries a
`RADIN_MODEL_<ROLE>` token instead — `PLANNING`, `EXECUTION`, `DEBUG`,
`FACTFIND` in `lib/radin-execute-prompts.md`, `REVIEW` in
`skills/radin-execute/SKILL.md`. `install.sh` asks — one pick for every
role by default, or per role — and its `set_role_models` sed
writes the answers in.
Defaults are sonnet,
except fact-finding: it retrieves a checkable fact and its prompt already
demands the evidence that establishes it, so haiku is enough and the router
can reject a wrong answer.

Don't hardcode a model name back into any of those files, and don't add a role
without a token — `set_role_models` exits non-zero if a token survives, but it
cannot notice a literal that was never a token. New role: add the token, a
`MODEL_<ROLE>` default, a picker, and a `-e` clause in `set_role_models`.

## The code-graph companion (codebase-memory-mcp)

`codebase-memory-mcp` is radin's only code-intelligence companion: one MCP
server, no second graph tool, no fallback to another one. These rules hold it
in place:

- **Install it whole or not at all.** `install.sh` installs the binary with
  `--skip-config`, sets `auto_index true`, then runs `radin cbm-config install`
  — upstream's own `codebase-memory-mcp install -y`, which writes its skill,
  three graph agents, the user-scope MCP entry and the
  `SessionStart`/`SubagentStart`/`PreToolUse` hooks that route Grep/Glob to the
  graph. Half a tool is not a choice worth offering, and the user-scope MCP
  entry is what makes every repo work with no per-project step.
- **`lib/radin-cbm-config.sh` makes that write non-destructive.** Upstream
  [#1200](https://github.com/DeusData/codebase-memory-mcp/issues/1200) (open,
  maintainer-confirmed, unfixed through v0.10.8) replaces the whole
  `SessionStart` array in `~/.claude/settings.json` instead of merging, so it
  drops caveman's and ponytail's hooks. The script snapshots `settings.json`
  and `~/.claude.json` into `~/.claude/.radin/backups/`, runs their installer,
  then puts back every hook entry and `mcpServers` key that was there before
  and is now gone — pre-existing entries first, upstream's after, deep-equal
  entries never duplicated, so it is idempotent. `radin cbm-config repair` is
  the same restore against the newest snapshot, for after
  `codebase-memory-mcp update` reruns the write. Drop the snapshot step and the
  next machine loses hooks silently; that is the whole reason this file exists.
  When #1200 closes, the restore becomes a no-op that reports `INTACT` — leave
  it in, don't celebrate by deleting the safety net. The same script forces
  upstream to rewrite what it would otherwise keep from another machine: it
  stashes `<config-dir>/hooks/cbm-*`, prunes hook entries whose command path is
  gone, and replaces a dead `mcpServers` command. Reinstalling has to be able
  to fix a wrong path, or a shared `~/.claude` stays broken on every machine
  but the first.
- **A symlinked `~/.claude` needs `CLAUDE_CONFIG_DIR`.** Upstream refuses
  every write under a symlinked config directory and then drops Claude Code
  from its target list while still exiting 0
  ([#1722](https://github.com/DeusData/codebase-memory-mcp/issues/1722),
  closed unresolved through v0.10.8) — no skill, no agents, no hooks, and
  `install.sh` printing that the tool is wired. `lib/radin-cbm-config.sh`
  resolves the link (`cd` + `pwd -P`; stock macOS has neither `realpath` nor
  `readlink -f`) and passes it as `CLAUDE_CONFIG_DIR`, which upstream honours.
  That override also moves upstream's MCP entry to
  `$CLAUDE_CONFIG_DIR/.claude.json`, so `adopt_staged_mcp` merges that one key
  into `~/.claude.json` — the file Claude Code reads when the user's own
  environment sets no `CLAUDE_CONFIG_DIR`. Never pass the variable empty:
  upstream treats it as set.
- **`cbm_wired` is the install's exit status, not a message.** Upstream exits
  0 whether or not it configured Claude Code, so `cmd_install` ends non-zero
  when neither the hooks nor the MCP entry are there, and `install.sh`'s
  existing fallback branch runs. Don't turn that back into a printed line: a
  false "wired" line is how a machine ends up with half a tool and nobody
  noticing.
- **`python3` is the one hard dependency of that path**, since the restore is
  JSON surgery. Without it `install.sh` skips upstream's configuration
  entirely and falls back to `radin cbm-hooks claude-md`, because running the
  destructive write with no way to undo it is worse than a smaller install.
- **The bracket's limits are written down** in
  `docs/technical-constraints.md`'s "What radin's codebase-memory-mcp bracket
  does and does not cover" (two files and one client only, restore is not
  rollback, newest snapshot wins, snapshots are user data, uninstall is
  asymmetric, `.mcp.json` path is machine-specific). Read it before you tell a
  user they are covered, and before changing `lib/radin-cbm-config.sh`. The
  user-facing half of the same list is README's "Caveats worth knowing".
- **`lib/radin-cbm-hooks.sh` is the fallback wiring**, merge-only: the
  CLAUDE.md section and a repo's `.mcp.json` entry, for the no-`python3` path
  and for anyone who ran `codebase-memory-mcp uninstall` but kept radin. It
  writes no hook — `auto_index` plus the tool's own watcher keep the graph
  current, so a reindex hook buys nothing. Extend that script rather than
  writing a second one.
- **Tool names live in four places only**: `skills/radin-plan/SKILL.md`
  (exploration), `skills/radin-review/SKILL.md` (`detect_changes` first),
  `lib/radin-execute-prompts.md` (execution, debug, fact-finding),
  and the
  CLAUDE.md section inside `lib/radin-cbm-hooks.sh`. Between them they name
  `index_repository`, `list_projects`, `search_graph`, `search_code`,
  `trace_path`, `detect_changes`, `query_graph`, `get_graph_schema`,
  `get_code_snippet` and `get_architecture` — every one from upstream's [MCP
  Tools](https://github.com/DeusData/codebase-memory-mcp#mcp-tools) table.
  Check a name against that table before you write it: a name that isn't
  there costs a failed call plus a fallback in every sub-agent that reads the
  prompt. Each mention also says a graph hit is a pointer — read the file
  before editing, never claim absence from an empty result.

## Constraints

**Never touch anything in `~/.claude` (`~/.config/.claude`) besides what
radin itself added.** `~/.claude/skills` shared directory — consumer's other
skills/tools live there too.
`~/.claude/.radin/lib` radin's own global tool directory (distinct from
per-repo `<repo-root>/.claude/.radin/` backlog namespace — same `.radin`
name, different scope: this one holds shared scripts like
`radin-backlog.sh`, not backlog state). `install.sh` may only `cp`/`cp -r`
radin's own named files (radin's own `skills/<name>/`, `lib/*` into
`~/.claude/.radin/lib/`) and `mkdir -p`. Two exceptions:

1. It rewrites the block between `<!-- radin:begin -->` and
   `<!-- radin:end -->` in `~/.claude/CLAUDE.md` (agent guidance on when to
   use radin). Only that block — everything outside the markers passes
   through untouched, which is what makes writing it unconditionally safe on
   a file radin doesn't own.
2. `lib/radin-cbm-config.sh` copies `~/.claude/settings.json` and
   `~/.claude.json` into `~/.claude/.radin/backups/` before handing `~/.claude`
   to `codebase-memory-mcp install`, then writes those two files again to put
   back what that install dropped (upstream #1200). It only ever restores an
   entry that was in the snapshot and is now missing, never adds an entry of
   radin's own, and never deletes a snapshot. It does drop what it can see is
   dead: a hook entry whose command is a path that does not exist, and an
   `mcpServers` command likewise — a `~/.claude` shared between machines
   carries the other machine's `$HOME`. It also moves
   `<config-dir>/hooks/cbm-*` into `~/.claude/.radin/backups/hooks.<stamp>/`
   before that install, because upstream bakes an absolute `$HOME` into each
   hook script and leaves an existing one alone. Moved, never removed.

Never `rm`. Never wildcard-delete directory. Never overwrite
file radin didn't ship. Call out explicitly on any edit to `install.sh`.

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

**Companion-tool installs advisory only.** `install.sh` delegates to each
tool's own installer and never guarantees it succeeds: a failure warns and
the run continues. Installs are not optional. Only concurrency and sub-agent
models are asked about.

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
