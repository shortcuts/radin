# Shared: Implementation Planning Method

Single source of truth for how a task gets turned into an implementation plan,
shared by `radin-plan`'s planning sub-agent and `radin-execute`'s fallback
(no-existing-plan) path. Both read this file instead of embedding their own
planning instructions, so an improvement to the method benefits both callers.
The two differ only in what happens to the result: `radin-plan` writes it to
a plan file and stops; `radin-execute`'s sub-agent keeps it in-session and
moves straight into implementing it.

## Method

1. Read the task's backlog entry (and, if scoped to a sub-task, the specific
   scope text) to understand what's being asked.
2. Explore the codebase as needed: current structure, affected files,
   existing patterns, constraints.
3. Invoke the `/ponytail` skill, then apply its ladder to produce the plan:
   - The minimum files to touch — no speculative scope.
   - The concrete change in each file.
   - Order of operations, where it matters.
   - How to verify the change (tests/checks to run), per the ladder's
     "lazy code without its check is unfinished" rule.
4. Surface any open questions or risks the plan surfaced — don't silently
   resolve genuine ambiguity.

## Caller contract

- Do NOT implement the change, run builds/tests, or commit while producing
  the plan — planning and implementing are separate steps even when the same
  sub-agent does both in sequence.
- The plan is scoped to exactly the task/sub-task text the caller pointed at
  — don't expand or narrow it.
