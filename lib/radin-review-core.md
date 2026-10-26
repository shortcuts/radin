# Review Core

The review every radin level runs: a plan before execution, a staged diff
before its commit, a session's commits after the run. `/radin-review` adds the
human triage on top. Run it inline. A caller that reads this file is a leaf or
an agent and reaches no user.

<!-- if:!LEVEL_diff -->
`radin-prompt.sh` embeds the `diff` slice of this file in the execution
prompt and drops every block between an `if:!LEVEL_diff` line and its `end`
line.
<!-- end -->

## Inputs

The caller names the level, the scope and the spec:

| Level | Scope | Spec |
| --- | --- | --- |
<!-- if:!LEVEL_diff -->
| `plan` | the plan file | the task file, its acceptance criteria |
<!-- end -->
| `diff` | `git diff --cached` | the plan file(s), else the task file; the acceptance criteria |
<!-- if:!LEVEL_diff -->
| `session` | the commits, as `RADIN_CLI scope <range>` prints their diff command | the task file and plan file(s) of each id `RADIN_CLI scope --specs <range>` prints (its `plan` column names the plan file(s)) |
<!-- end -->

Read the spec in full before reading the scope.

## Review

Invoke the passes for the level against the scope:

| Level | Passes |
| --- | --- |
<!-- if:!LEVEL_diff -->
| `plan` | none |
<!-- end -->
| `diff` | `/ponytail:ponytail-review` |
<!-- if:!LEVEL_diff -->
| `session` | `/thermo-nuclear`, `/ponytail:ponytail-review` |
<!-- end -->

Then report:

1. **Spec coverage.** Every acceptance criterion, `**Raised as:**` requirement
   and `**Decision:**` line the scope misses, implements only partly, or
   contradicts. Quote the spec line.
   - `plan`: each criterion needs a `## Changes` entry and a `You see:` line or
     a `## Testing` box that checks it.
   - `diff` and `session`: each plan `You see:` line and each criterion needs a
     `**Fact:** [measured]` line or test output that proves it. An unproven
     criterion is a finding, whatever the code looks like.
2. **Scope creep.** Every change no criterion or plan entry asks for.
   - `diff`: every staged file outside the plan's `## Changes`.
3. **Simplest native solution.** Every place the scope is more code, more
   abstraction or less native than the spec needs, and every structural
   finding a pass raises. A documented repo rubric (`AGENTS.md`,
   `CLAUDE.md`, `CONTRIBUTING.md`) overrides a pass's generic judgment; a
   pass finding without one stays labeled "possible <name>".
4. **Repo rubrics.** Every rule the scope breaks, citing the file and rule.
5. **Comments.** Every comment the scope adds that breaks the comment rule
   (`RADIN_LIB/radin-comment-rule.md`; an execution prompt's step 6 already
   holds it, so read no file there), and every existing comment the scope
   deletes or rewords without the task asking. Apply that rule's test. Level
   `plan` skips this item.
6. **Plan only.** A decision left for the executor to invent, a
   `## Decisions` claim with no source, a `## Alternatives rejected` entry
   missing for a real fork, and an approach the repo contradicts.

Skip anything a formatter or linter already enforces. Cite one `path:line` the
scope introduced; a problem that predates the scope qualifies only when a
changed line makes it wrong, and that line is the citation. For a plan, cite
the section and entry.

## Prove each finding

Give each finding a severity (`critical`, `warning`, `nit`) and the evidence
rung it reached:

- `cited`: you pointed at the line.
- `traced`: you followed a caller or data path and showed the bad case
  happens. Find callers by the explore rule.
- `ran`: you executed the changed path and saw it fail. Every `critical` at
  `diff` or `session` level reaches `ran`.

A `cited` finding that depends on an input or a state ("what if this is null")
survives only when a call site or data path produces that input. Drop it
otherwise. Drop a finding that cites no rubric, quotes no spec line and shows
no incorrect behavior.

## Return

One line per finding, most severe first:

`<severity> <path:line or plan section> — <claim> [<rung>: <evidence>]`

No finding is a valid result: say `no findings`.
