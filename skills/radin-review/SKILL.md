---
name: radin-review
description: |
  Review a commit, PR, directory or range for the simplest native solution
  (ponytail), maintainability (thermo-nuclear) and documented repo
  rubrics, triage findings with the user, and log the kept ones as backlog
  entries. Use for /radin-review, "review and log to backlog".
---
# Review to Backlog

Review a caller-specified scope in one pass, and persist every finding the
user keeps as a backlog entry instead of terminal output. That leaves a
durable backlog `radin-execute` (or a human) works through later.

One question drives the review: is this the simplest, most native solution
that still meets the thermo-nuclear constraints and this repo's documented
rubrics? The originating backlog entry or its plan is context for that
question: behaviour it asked for but the scope lacks, and behaviour the scope
adds unasked, are ordinary findings.

**Sub-agent caller** — `radin-execute`'s Phase 6 dispatches this skill that
way, and a sub-agent reaches neither the user nor a spawned agent's result:
run every step inline, skip each `AskUserQuestion`, log every in-scope
finding, and say in Step 6's report that no triage happened.

**Leaf caller** — an execution leaf invokes this skill with scope `staged`
before it commits, so the review is part of its verify loop. Run it inline as a
sub-agent caller does, and take the spec the invoking prompt names (Step 2,
rung 1). The leaf, not the backlog, takes the `critical` and `warning`
findings: relay them for it to fix now. Step 5 logs the `nit` findings only,
and skips `review-findings`, since no commit exists yet to attribute.

## Step 1: Resolve the scope

```bash
RADIN_CLI scope [<arg>]
```

It prints `type`/`scope`/`command`/`passes` lines, and Step 3 invokes exactly
the skills the `passes` line names. Route on its exit code:

- **1**: not a commit, PR, directory, range, or `since <date>`. Report it and
  stop.
- **2**: ambiguous, candidates on stderr (e.g. both a PR number and a
  directory). Ask which one; a sub-agent caller reports both readings and
  stops.

State the resolved scope in one line — `Scope: commit a1b2c3d`,
`Scope: directory src/auth/` — then capture both inputs the axes need, here
and once:

- **The diff command.** The `command` line is the scope's one diff command.
  Record it verbatim and paste that same string into every later Bash call and
  both briefs.
- **The commit list.** `RADIN_CLI scope --commits [<the same scope arg>]`
  prints one `<hash> <subject>` line per commit. A `dir` scope prints nothing:
  it has no commit list, and the brief says so.

Run the `command` before the review starts. No output — for a `dir` scope, no
file under the path — means report "nothing to review in `<scope>`" and stop.
Write no backlog entry to prove the skill ran.

## Step 2: Resolve the spec

The review reads the originating backlog entry or its plan as context. Work
these rungs in order and stop at the first that yields a spec:

1. **The invoking prompt named one** — a backlog id, a title, or a path. For an
   id or title:
   `RADIN_CLI backlog field "<it>" TASK_FILE` and
   `RADIN_CLI backlog field "<it>" PLAN_PATHS` (its exit 1 means no plan; the
   task file alone is then the spec). For a path: that file is the spec.
2. **The backlog holds it.** `radin backlog add` stamps each entry with its
   creation instant and branch, and `task-done` copies the creation instant,
   commit and branch into `completed.json`. One call joins them to the scope:

   ```bash
   RADIN_CLI scope --specs [<the same scope arg as Step 1>]
   ```

   It prints one `id`, `created`, `branch`, `commit`, `source` line per
   candidate, oldest first. `source` says how the entry joined: `commit` (the
   task's commit is in scope), `reflog` (a squash or rebase rewrote that
   commit, and the review branch's reflog still lists it) or `pending` (an
   open entry recorded on the review branch). Route on the result:

   - **Exit 4**: a recorded commit no longer exists and HEAD sits on no branch.
     Report the stderr line and stop the review.
   - **No output**: fall to rung 3.
   - **Lines**: take every line without asking. Never ask the user to confirm,
     order or drop entries. A sub-agent caller takes the `commit` and `reflog`
     lines only: a `pending` entry is unfinished work, not what the scope
     implemented.

   A `pending` id resolves as in rung 1. For the others,
   `RADIN_CLI state completed-show "<id>"` names the plan the task ran
   against: its `plan` line carries the recorded paths, comma-separated. Also
   run `RADIN_CLI state trace "<id>"` for each completed id: when its `facts`
   line names a file, that file is part of the entry, because it records where
   the implementation departed from the plan on purpose and why.

   Then sort the entries into two roles. Read each plan and decide:

   - **Follow-up**: the plan answers a review finding (it quotes a
     `**Finding:**`, a `**Severity:**` or a `review` origin) or fixes work an
     earlier entry shipped. These are **decisions**.
   - **Feature**: every other entry. These are the **spec**.

   The sort is yours; never put it to the user. When every entry is a
   follow-up, there is no spec, only decisions: the review runs with them and
   reports `no spec available` in Step 6.
3. **Ask.** One `AskUserQuestion` offering the top entries from
   `RADIN_CLI backlog list` as options, with the tool's free-text field
   carrying a path the user types instead. "There isn't one" falls to rung 4.
4. **Skip.** No spec: the review runs without one. Say so once here, and report
   `no spec available` in Step 6. A sub-agent caller arrives here straight from
   rung 2.

## Step 3: Run the review

Dispatch one sub-agent. The brief is self-contained: paste in full the resolved
scope line, Step 1's `command` string and commit list verbatim, and the
citation rule below. The spec, when Step 2 found one, goes in as absolute
paths with "read it in full before reviewing"; the sub-agent's `Read` is the
access that paste-in-full rule exists to provide. The decisions go in the same
way, labelled: "these entries fixed earlier findings on purpose; the scope's
behaviour they describe is settled, so never raise it again as a finding unless
a changed line contradicts the decision."

> Every finding cites one `path:line` the scope introduced: for a diff scope
> the lines it adds or changes, for a `dir` scope the files under that path.
> Read surrounding code for context, never to find findings. A problem that
> predates the scope qualifies only when a changed line is what makes it wrong,
> and that changed line is the citation. Skip anything a formatter or linter
> already enforces.
>
> Give each finding a severity (`critical`, `warning` or `nit`) and its
> evidence: the rung it reached — `cited` (you pointed at the line), `traced`
> (you followed a caller or data path and showed the bad case happens) or
> `ran` (you executed it and saw it fail) — then the reasoning or output.
> Trace callers and data paths through `codebase-memory-mcp`'s MCP tools
> before Grep: a graph hit is a pointer, so read the file before you cite it,
> and never conclude a caller is absent from an empty result.

**Brief.** Invoke `/thermo-nuclear` against the scope, then every skill Step
1's `passes` line names. Report — per file/hunk where relevant —
(a) every place the scope is more code, more abstraction or less native than
the task needs, and every structural finding the passes raise: name it and
quote the hunk; (b) every place the scope breaks a rubric this repo documents:
cite the rubric, file and rule; (c) with a spec: requirements it asked for that
are missing, only partly implemented or implemented wrongly, and behaviour the
scope adds that it never asked for — quote the spec line, and cite the
`path:line` it lands on. A documented repo rubric overrides a pass's generic
judgement, and a pass finding stays a labelled judgement call
("possible <name>") — the label reaches the backlog entry an agent later acts
on without the review in front of it. Report findings only, each as its claim, citation, severity and evidence.

Relay the report before any triage, in the order the sub-agent gave it.

## Step 4: Filter, classify, triage

Nothing reaches the backlog until the user agrees to it. The citations go
through one filter, which drops the out-of-scope findings:

```bash
printf '%s\n' "<path:line per finding, one per line>" |
  RADIN_CLI scope --in-scope [<the same scope arg as Step 1>]
```

Keep the findings on the `in` lines, drop the `out` ones, and carry the
`dropped` count into Step 6. Cite one line per finding; for a range, its first
line. A finding about missing behaviour cites the in-scope line the
requirement should have landed on — the hunk with the partial behaviour, or the
one nearest where it belongs. A finding with genuinely no in-scope line stays
in Step 3's relay, and Step 6 names it as unlogged.

Then test each `cited` finding that depends on an input or a state ("what if
this is null"): it survives only when you find a call site or data path that
produces that input. Find the callers through `codebase-memory-mcp`'s MCP
tools, read them to settle it, and dismiss the finding when none does — an
empty graph result is not proof, so confirm with Grep before dismissing. A `traced` or `ran` finding already carries that proof.

Then classify each survivor. This is a rule, not a judgment: **fix** for
incorrect behavior, including a missing, partial or wrongly implemented
requirement, and **refactor** for everything else, scope creep included.

Then attribute each survivor's origin, so the review shows whether defects
trace to plans:

```bash
printf '%s\n' "<path:line per survivor>" |
  RADIN_CLI scope --attribute [<the same scope arg as Step 1>]
```

Each line carries the citation, its task id and its plan paths (comma-joined);
`none` in either field, a `dir` scope or an untraced commit means class
`none`. Otherwise settle the class in this order:

1. `RADIN_CLI state plan-covers "<plan csv>" "<cited path>"` prints `out`:
   class `executor`, the code touched a file outside the plan's Changes.
2. Otherwise read the plan's `## Decisions`: class `plan` when a Decisions line
   prescribed the flaw or left the choice open for the executor to guess,
   `executor` when the plan was right and the code deviated. Quote that
   Decisions line, or write `no Decision covers it`, so the label can be
   audited. For class `plan`, also name the plan-template section whose entry
   would have caught the flaw (`outcome`, `decisions`, `changes`,
   `reach-and-reuse`, `rubrics-triggered`, `modes-and-states`, `order`,
   `testing`, `out-of-scope`), or leave it empty when no section would have.

A sub-agent caller does this inline.

Then group the survivors, so one backlog entry covers one piece of work. Merge
survivors into a group when one fix touches them all:

- They cite the same file, or overlapping hunks, or share one root cause or
  remedy.
- They share one task id, origin class and plan paths. Attribution then
  stays true for the whole group.

A group takes `fix` when any member is `fix`, and the highest member severity.
Leave a survivor alone when no other survivor shares its fix.

Print the groups as a numbered list — number, category, severity, location,
the finding in a clause. A group lists each member on a lettered sub-line with
its location and clause. The list is the triage handle for what Step 3 already
printed, so it carries no further detail.
Mark the ones you recommend tackling, on severity and effort rather than
count; recommending all of them is a valid answer.

Then gate on `AskUserQuestion` (single select):

1. **Recommended only** — log the groups you marked.
2. **All** — log every in-scope group.

A free-text answer names the numbers you printed; read it as that subset of
groups and nothing more, and restate the subset in one line before continuing.

## Step 5: Log the agreed findings to backlog

The body carries what a sub-agent with no review context needs to act on the
group. A group repeats `**Finding:**`, `**Severity:**` and `**Evidence:**` once
per member, each opened with the member's `path:line`; the entry's
`**Preferred remedy:**` covers all members:

```bash
RADIN_CLI backlog add <fix|refactor> "<short title>" <<'EOF'
**Scope:** <what was reviewed, from Step 1>
**Finding:**
<the problem as the review stated it: direct, specific. A finding against the
spec opens with the spec line the brief quoted.>
**Severity:** <critical|warning|nit>
**Origin:** task <id|none> · plan <path|none> · class <plan|executor|none> — <the quoted ## Decisions line, or the reason>
**Evidence:** <rung: cited|traced|ran> — <the reasoning or output the brief gave>
**Preferred remedy:**
<the concrete restructuring suggested>
EOF
RADIN_CLI backlog set-meta <id> location "<the cited path:line>"
```

For a group, `location` is the first member's citation.

For class `plan` and `executor`, end the `**Origin:**` line with
`Read <plan path> ## Decisions before changing code.`, so the fix's sub-agent
reads the original plan's decisions.

Log one entry per agreed group, in the order presented. Log nothing the
user discarded.

After the last `add`, journal the logged findings in one call (skip it when
nothing was logged) and keep its output for Step 6. Write one row per member
finding, not per entry, so the rollup counts findings. Task files are deleted at
`task-done`; the journal event keeps the finding-to-plan link. A class `plan`
finding carries its Step 4 section as a fourth column, empty when it has none;
other classes carry no fourth column:

```bash
printf '<task id or empty>\t<class>\t<plan path or none>[\t<section>]\n...' |
  RADIN_CLI state review-findings
```

## Step 6: Report back

- The resolved scope reviewed, and the spec path or `no spec available`.
- The entries logged, one line each — these are the `add` calls you just made.
  A group's line states how many findings it covers.
- The origin rollup: `review-findings`' output verbatim (for example
  `12 findings: 9 plan (3 tasks), 2 executor, 1 none`, then one line per task).
- Findings the user discarded, findings dropped as out of scope, and findings
  dropped for having no in-scope line: three counts, no detail.
- Findings dismissed by Step 4's call-site test: one line each, the finding
  and the reason, so the user can overrule a dismissal.
- The backlog index path.
- Zero findings: say the review passed. Every finding discarded: report that.
  Either way, write no entry to prove the skill ran.

End with one line: total findings, and the worst issue.
