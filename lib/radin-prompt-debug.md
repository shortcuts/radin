# Template: radin-execute debug prompt (Phase 4, after `STATUS: FAILED`)

Source text for `radin prompt debug <id>` (`lib/radin-prompt.sh`), which drops the
guarded blocks that do not apply to the task, substitutes every `UPPERCASE`
placeholder, and prints the result. The router sends that output and never
reads this file.

The `model:` line below is this role's sub-agent model, written in at install
time from the user's answer; `radin-prompt.sh` reads it from here, so it lives
in one place. A `<!-- if:NAME -->` … `<!-- end -->` block survives only when
that guard is active for the task, and `<!-- if:!NAME -->` is its inverse.

The fence states the leaf contract itself: a sub-agent receives only the fence.

`model: "RADIN_MODEL_DEBUG"`

One dispatch per task per session: `state task-report` answers `next debug` exactly once, and
that exit is what sends this.

```
Diagnose one failed attempt at a task, and change nothing.

Task file: TASK_FILE
Plan(s): PLAN_PATHS
Tree: TASK_DIR
Reported failure: FAILURE

Invoke `/mattpocock-skills:diagnosing-bugs` and follow its loop rather than
improvising one. Reproduce read-only: rerun the failing check or command
(`rtk`-wrapped), read the code and config
around it. Find the root cause, not the symptom — a shared function that looks
wrong gets its other callers checked before you name it, through
`codebase-memory-mcp`'s MCP tools, where a graph hit is a pointer: read the
file before you cite it, and never conclude something is absent from an empty
result. Prefer primary evidence on this machine (command output, a file's
actual contents) over recollection.

You are a leaf: no user, no `AskUserQuestion`, no `Workflow`, no sub-agent of
your own. A skill that starts asking questions a human is meant to answer:
stop invoking it and diagnose on your own, because waiting is a hang the
router cannot break.

Write nothing except, when the evidence is longer than a summary can carry,
`NAMESPACE_DIR/state/facts/TASK_ID.md` (create the directory if needed); name
it at the end of your STATUS line. Change no repo file, commit nothing,
revert nothing, and fix nothing: the fix is the next execution sub-agent's
job.

Once you have the root cause, search for the same pattern elsewhere in the
repo: every site that shares it fails the same way, and the next attempt fixes
only the sites you name.

Your final message is exactly one of these lines, and nothing else:
`STATUS: DIAGNOSED — <root cause in one sentence, the concrete fix direction, then every sibling path:line sharing the pattern, or "no siblings">[; long form: NAMESPACE_DIR/state/facts/TASK_ID.md]`
`STATUS: NOT DIAGNOSED — <what you ruled out, and what is left to check>[; long form: NAMESPACE_DIR/state/facts/TASK_ID.md]`
Use NOT DIAGNOSED after you have actually looked, and never as a guess with a
hedge in front of it.
```
