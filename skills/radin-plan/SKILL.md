---
name: radin-plan
description: |
  Write an implementation plan for one backlog entry, touching no code. Use
  for /radin-plan, "plan this backlog entry", "write a plan for X before we
  execute it". Scope is one task, not the whole backlog.
---
# Plan a Backlog Entry

**You own the plan, not the code.** The plan is a checklist an executor runs
box by box, and a reviewer audits from the evidence each box names. It runs
inline in whichever context invokes it. A caller that cannot reach the user
says so in its prompt; the branches marked "non-interactive" are then the
defaults, and anything only the user could settle is reported and stops the
run.

## Step 1: Resolve the task scope

```bash
RADIN_CLI backlog plan-target "<scope id/title/keyword>"
```

It prints `id`/`title`/`task_file`/`plan_file` lines, plus a
`facts<TAB><path>` line when the entry carries one, plus one
`plan<TAB><path>` line per plan the entry already has. Route on its exit code:

- **0**: resolved and unplanned. Use it.
- **1**: nothing matches. The task isn't in the backlog yet. Classify it into
  `feat` (new capability), `fix` (broken behavior), `chore` (maintenance:
  docs, tooling, cleanup) or `refactor` (structure only, no behavior change),
  create it without asking, then re-run `plan-target` on the printed id.

  ```bash
  RADIN_CLI backlog add <category> "<short title>" <<'EOF'
  <the task as the caller stated or clearly implied it, and why it matters
  if not already obvious>
  EOF
  ```

- **2**: several entries match; it prints them as `candidate` lines on stderr.
  Ask which one.
- **3**: already planned; the `plan` lines are the existing paths. Show them and
  ask whether to re-plan (overwrite) or stop. Stop unless confirmed.

Non-interactive, for exits 1-3: report what `plan-target` printed and stop. The
scope came from an existing entry, so no match means backlog drift: the run
adds no entry, picks no candidate, and overwrites no plan.

## Step 2: Judge whether the scope should split

Split only when the entry bundles unrelated changes that can each be planned
on its own. Interactive: state your read (split or not, and why) and confirm
it; a confirmed split lists short titles and one-line descriptions with full
coverage and no overlap. Non-interactive: no split.

## Step 3: Write each plan

For each sub-task, in order:

1. Read the entry's file. A sub-task from a split has only its one-line
   Step 2 description as scope, so plan just that part.
2. Explore the repo as far as the plan needs, through `codebase-memory-mcp`'s
   MCP tools before Grep/Glob/Read. Carry the project's own vocabulary into
   the plan, its glossary or domain-model doc where it has one, and respect
   any ADR covering the area.
3. Settle each open fact before you write:
   - A fact you can observe by running something (a command, a scratch
     script, a one-off probe outside the repo tree) is yours to run. Delete
     the scratch file after.
   - Third-party API or library behavior local code cannot confirm: read the
     entry's `**Fact:**` lines and the `facts` file Step 1 printed first.
     Still open, interactive: hand the question to
     `/mattpocock-skills:research` naming
     `<repo root>/.claude/.radin/state/facts/<task-id>.md` as the file to write
     to, plan the parts that do not hinge on it meanwhile, then record it:

     ```bash
     RADIN_CLI backlog append "<id>" <<'EOF'
     **Fact:** <the answer in one sentence, naming the source that owns it>
     EOF
     RADIN_CLI backlog set-meta "<id>" facts "<the state/facts path above>"
     ```

     The skill asks you anything: drop it and name the question in the
     report. Non-interactive: name the question and stop, because
     `radin-batch`'s router owns the research arm
     (`lib/radin-batch-clarify.md`) and appends the answer to this task.
4. Sketch the seam the change will be tested at: the highest existing one,
   and a new one only at the highest point available. Interactive: confirm it
   with the user. Non-interactive: write on.
5. Apply the ponytail ladder already in your context to produce the plan.
   When the plan places a new module boundary or reshapes an interface,
   invoke `/mattpocock-skills:codebase-design` for that part. Write it to the
   template below. Non-interactive: a question the entry, the repo and this
   conversation cannot answer ends the run as a report line, not an open
   decision in the plan.
6. Save the plan at the `plan_file` path Step 1 printed. For a sub-task from a
   split, re-run `plan-target "<id>" "<sub-task short title>"` and use the
   `plan_file` it prints.
7. Lint it and fix every line it prints, until it exits 0:

   ```bash
   RADIN_CLI backlog plan-lint "<the plan_file path>"
   ```

8. Insert the pointer:

   ```bash
   RADIN_CLI backlog add-plan "<id>" "<the plan_file path>"
   ```

This skill's whole output is the plan file(s), the plan pointer, and, when
research ran, the `**Fact:**` line and `facts` pointer. No source file is
edited, no build or test runs, nothing is committed.

### The plan template

Keep every heading, in this order. A section that does not apply reads
`n/a: <reason>`, so a reader sees it was considered.

<plan-template>

```markdown
# Plan: <task title>

**Task:** `<task id>` — <the `task_file` path Step 1 printed>

## Outcome

<One or two lines: what is true of the codebase once this plan is implemented.>

## Decisions

<Every choice the executor would otherwise have to make, settled here:>

1. <The question> → <the settled answer>. Why: <one line>. Source: <`path:line`, the read-only command that produced it, or the owning doc for third-party behavior>.

<A change that adds state settles its data shape here, before any logic: a
state machine over scattered booleans, a table over branching, a typed model
over repeated shape assumptions. A claim with no source is an open question,
which ends the run per Step 3; a decision the executor has to invent is a
defect in this plan.>

## Alternatives rejected

- <Each approach weighed, and the one line why it lost.>

## Changes

<One entry per file to touch, the minimum set:>

- `<path>` — <the concrete change, in prose: the symbols to touch and what
  becomes of each. No line numbers, and no pasted code.>
  You see: <the one observable result that proves this entry landed: the exact
  output, log line, exit code or screen state.>

<Exception for code: a snippet that encodes a decision more precisely than
prose can (a schema, a type shape, a state machine, the exact string a test
asserts on), trimmed to the decision-rich part.>

## Reach and reuse

<One `codebase-memory-mcp` query pass per changed or new symbol.>

- `<symbol>` — <`path:line` of each caller or implementer, test doubles
  included> → <in Changes, or excluded: reason>
- `<new symbol>` — reuse: <`path:line` | none — searched <query>>; sibling:
  <`path:line` whose naming and structure it matches>

<A changed shared primitive lists every consumer; each one is a Changes entry
with its own You see line, or excluded with a reason.>

## Rubrics triggered

<Sources: the repo's root `AGENTS.md` or `CLAUDE.md` (follow its `@AGENTS.md`
import) and the docs index or `CONTRIBUTING.md` they point at.>

- <rubric> (`<file>:<line or heading>`) → <file added to Changes | not needed:
  reason>
  - `<path>` — <n> lines (budget <b>), for each Changes file a line budget
    covers

## Modes and states

<Every enum, flag, state field or guard clause the changed symbols and their
callers branch on.>

- <mode or state> (`<path:line>`) → <gated here: decision | ungated: reason |
  not reachable: reason>

## Order

<The steps that must happen in a given order, numbered, each with the one line
saying why it gates the next, or "Any order.">

## Testing

**Seam:** <the seam from Step 3, and why it is the highest available.>
**Prior art:** <an existing test in this repo whose shape the new test copies.>
**What to test:** <external behavior only: what a caller observes.>

Tests alone are not sufficient verification.

- [ ] <one line per check, as the command that runs it>
- [ ] Live: <the real path a user takes (the CLI command, the TUI key, the
  request), the command that drives it, and the output that passes>

## Risks

- <Each risk, the Changes entry it lands in, and what the executor watches.>

## Out of scope

<What a reader might expect here and this plan does not do, each with where it
belongs, or "Nothing: the entry's scope is covered in full above.">
```

</plan-template>

## Step 4: Review each plan

Review it with `RADIN_LIB/radin-review-core.md` at level `plan`: scope the
plan file, spec the `task_file` Step 1 printed. Interactive: dispatch one
sub-agent whose brief names the core file, the level and both absolute paths,
and says "read all three in full before reviewing". Non-interactive: read the
core and run it inline.

Relay the findings before editing anything, then fix each one by editing the
plan file in place and re-run Step 3's lint. The backlog gains nothing,
because nobody has written this code yet.

A finding that the approach itself is wrong, or that leaves a decision for
the executor to invent, outruns an edit. Interactive: invoke
`/mattpocock-skills:grilling` over those findings, one at a time, and fold
each settled answer into `## Decisions` before the next. Non-interactive:
report the finding and stop.

## Step 5: Report back

**Reply:** one line per plan, in the form
`✅ <id> planned. Plan: <path>. Lint: clean. Review findings: <n> (<n> fixed).`
and a closing line `Next: radin-batch (or a human) can implement from the plan(s) above.`
