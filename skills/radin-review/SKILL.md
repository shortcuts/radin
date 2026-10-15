---
name: radin-review
description: |
  Review a commit, PR, directory or range for the simplest native solution,
  maintainability and documented repo rubrics, triage findings with the user.
  Use for /radin-review, "review and log to backlog".
---
# Review

Review a scope, then triage the findings with the user: each kept group goes
to the backlog or gets tackled now. An agent caller reads
`RADIN_LIB/radin-review-core.md` and follows it instead of this skill.

## Step 1: Resolve the scope

```bash
RADIN_CLI scope [<arg>]
```

It prints `type`/`scope`/`command`/`passes` lines, and Step 3 hands the
reviewer exactly the skills the `passes` line names. Route on its exit code:

- **1**: not a commit, PR, directory, range, or `since <date>`. Report it and
  stop.
- **2**: ambiguous, candidates on stderr (e.g. both a PR number and a
  directory). Ask which one.

State the resolved scope in one line, `Scope: commit a1b2c3d` or
`Scope: directory src/auth/`, then capture both inputs the review needs, here
and once:

- **The diff command.** The `command` line is the scope's one diff command.
  Record it verbatim and paste that same string into every later Bash call and
  the brief.
- **The commit list.** `RADIN_CLI scope --commits [<the same scope arg>]`
  prints one `<hash> <subject>` line per commit. A `dir` scope prints nothing:
  it has no commit list, and the brief says so.

Run the `command` before the review starts. No output (for a `dir` scope, no
file under the path) means report "nothing to review in `<scope>`" and stop.

## Step 2: Resolve the spec

Work these rungs in order and stop at the first that yields a spec:

1. **The invoking prompt named one**: a backlog id, a title, or a path. For an
   id or title, `RADIN_CLI backlog field "<it>" TASK_FILE` and
   `RADIN_CLI backlog field "<it>" PLAN_PATHS` (exit 1 means no plan; the task
   file alone is then the spec). For a path, that file is the spec.
2. **The backlog holds it.**

   ```bash
   RADIN_CLI scope --specs [<the same scope arg as Step 1>]
   ```

   It prints one `id`, `created`, `branch`, `commit`, `source` line per
   candidate, oldest first. `source` says how the entry joined: `commit` (the
   task's commit is in scope), `reflog` (a squash or rebase rewrote that
   commit, and the review branch's reflog still lists it) or `pending` (an
   open entry recorded on the review branch).

   - **Exit 4**: a recorded commit no longer exists and HEAD sits on no branch.
     Report the stderr line and stop the review.
   - **No output**: fall to rung 3.
   - **Lines**: take every line without asking.

   A `pending` id resolves as in rung 1. For the others,
   `RADIN_CLI state completed-show "<id>"` names the plan the task ran
   against in its `plan` line, comma-separated. `RADIN_CLI state trace "<id>"`
   adds the file its `facts` line names to the entry.

   Sort the entries into two roles by reading each plan:

   - **Follow-up**: the plan answers a review finding (it quotes a
     `**Finding:**`, a `**Severity:**` or a `review` origin) or fixes work an
     earlier entry shipped. These are **decisions**.
   - **Feature**: every other entry. These are the **spec**.

   When every entry is a follow-up, there is no spec, only decisions, and
   Step 6 reports `no spec available`.
3. **Ask.** One `AskUserQuestion` offering the top entries from
   `RADIN_CLI backlog list` as options, with the free-text field carrying a
   path. "There isn't one" falls to rung 4.
4. **Skip.** No spec: say so once here, and report `no spec available` in
   Step 6.

## Step 3: Run the review

When the invoking prompt hands over a core review's findings for this scope,
skip the dispatch and relay those.

Dispatch one sub-agent with a self-contained brief:

- `Read RADIN_LIB/radin-review-core.md and follow it at level session` (level
  `diff` for a `staged` scope).
- The resolved scope line, Step 1's `command` string and commit list,
  verbatim.
- The spec and the decisions as absolute paths with "read it in full before
  reviewing". Label the decisions: "these entries fixed earlier findings on
  purpose; the scope's behaviour they describe is settled, so raise it again
  only when a changed line contradicts the decision."
- The skills Step 1's `passes` line names, as extra passes to invoke after
  the core's two.

Relay its report before any triage, in the order the sub-agent gave it.

## Step 4: Filter, classify, triage

Nothing is logged or acted on until the user agrees to it. The citations go
through one filter, which drops the out-of-scope findings:

```bash
printf '%s\n' "<path:line per finding, one per line>" |
  RADIN_CLI scope --in-scope [<the same scope arg as Step 1>]
```

Keep the findings on the `in` lines, drop the `out` ones, and carry the
`dropped` count into Step 6. A finding about missing behaviour cites the
in-scope line the requirement should have landed on. A finding with no
in-scope line stays in Step 3's relay, and Step 6 names it as unlogged.

Classify each survivor: **fix** for incorrect behavior, including a missing,
partial or wrongly implemented requirement, and **refactor** for everything
else, scope creep included.

Attribute each survivor's origin:

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
   Decisions line, or write `no Decision covers it`. For class `plan`, also
   name the plan-template section whose entry would have caught the flaw
   (`outcome`, `decisions`, `alternatives`, `changes`, `reach-and-reuse`,
   `rubrics-triggered`, `modes-and-states`, `order`, `testing`, `risks`,
   `out-of-scope`), or leave it empty when no section would have.

Merge survivors into a group when one fix touches them all:

- They cite the same file, or overlapping hunks, or share one root cause or
  remedy.
- They share one task id, origin class and plan paths, so attribution stays
  true for the whole group.

A group takes `fix` when any member is `fix`, and the highest member severity.

Sort each group into a bucket, each with a one-line reason. A group takes its
highest member's bucket.

- **Act on**: `critical` or `warning`, with a `traced` or `ran` rung, a quoted
  spec line or a cited rubric.
- **Consider**: `critical` or `warning`, with only a `cited` rung or a
  "possible <name>" label.
- **Noted**: a `nit`. When every survivor is Noted, Step 6 says the code is
  fine.
- **Dismissed**: a finding asking for an interface, config or generalisation
  with one caller or one value (premature abstraction), or one that cites no
  rubric, quotes no spec line and shows no incorrect behavior ("I would have
  done it differently").

Print the groups as a numbered list in the order Act on, Consider, Noted,
Dismissed: number, bucket and reason, category, severity, location, the
finding in a clause. A group lists each member on a lettered sub-line with its
location and clause.

Then gate on one `AskUserQuestion` with two single-select questions:

- Which groups: **Recommended only** (the Act on groups) or **All** (Act on
  and Consider).
- What to do with them: **Add to backlog** or **Tackle now**.

A free-text answer names the numbers you printed, Noted and Dismissed ones
included; read it as that subset of groups and nothing more, and restate the
subset in one line before continuing.

## Step 5: Act on the agreed findings

Build one body per agreed group. It carries what a sub-agent with no review
context needs to act on the group. A group repeats `**Finding:**`,
`**Severity:**` and `**Evidence:**` once per member, each opened with the
member's `path:line`; the `**Preferred remedy:**` covers all members:

```
**Scope:** <what was reviewed, from Step 1>
**Finding:**
<the problem as the review stated it: direct, specific. A finding against the
spec opens with the spec line the brief quoted.>
**Severity:** <critical|warning|nit>
**Origin:** task <id|none> · plan <path|none> · class <plan|executor|none> — <the quoted ## Decisions line, or the reason>
**Evidence:** <rung: cited|traced|ran> — <the reasoning or output the brief gave>
**Preferred remedy:**
<the concrete restructuring suggested>
```

For class `plan` and `executor`, end the `**Origin:**` line with
`Read <plan path> ## Decisions before changing code.`, so the fix's sub-agent
reads the original plan's decisions.

Act on each agreed group in the order presented, and on nothing the user
discarded:

- **Add to backlog**:

  ```bash
  RADIN_CLI backlog add <fix|refactor> "<short title>" <<'EOF'
  <the body>
  EOF
  RADIN_CLI backlog set-meta <id> location "<the cited path:line>"
  ```

  For a group, `location` is the first member's citation. Flag the entry
  `RADIN_CLI backlog set-meta <id> planning needed` unless its remedy touches
  one or two files with one obvious approach.
- **Tackle now**: invoke `/radin-do` with the body as its prompt, one group at
  a time, each to its Phase 5 summary before the next. `/radin-do` records the
  entry itself, so run no `add`.

After the last group, journal the agreed findings in one call (skip it when
nothing was agreed) and keep its output for Step 6. Write one row per member
finding, not per entry, so the rollup counts findings. A class `plan`
finding carries its Step 4 section as a fourth column, empty when it has none;
other classes carry no fourth column:

```bash
printf '<task id or empty>\t<class>\t<plan path or none>[\t<section>]\n...' |
  RADIN_CLI state review-findings
```

## Step 6: Report back

**Reply:**

- The resolved scope, and the spec path or `no spec available`.
- One line per agreed group: how many findings it covers, and the backlog id
  or the `/radin-do` outcome.
- The origin rollup, `review-findings`' output verbatim (for example
  `12 findings: 9 plan (3 tasks), 2 executor, 1 none`, then one line per
  task).
- Three counts, no detail: findings the user discarded, dropped as out of
  scope, and dropped for having no in-scope line.
- One line each, finding and reason, for every Dismissed group, so the user
  can overrule.
- The Noted count, and the backlog index path when any group went to the
  backlog.
- Zero findings, or only Noted ones: the review passed and the code is fine.
- A last line: total findings, and the worst issue.
