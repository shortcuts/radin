# Template: radin-batch debug prompt (Phase 4, after `STATUS: FAILED`)

Rendered by `radin prompt debug <id>`. `lib/radin-prompt.sh` holds the format.

`model: "RADIN_MODEL_DEBUG"`
`effort: "RADIN_EFFORT_DEBUG"`

One dispatch per task per session: `state task-report` answers `next debug` exactly once, and
that exit is what sends this.

```
Diagnose one failed attempt at a task, and change nothing.

Task file: TASK_FILE
<!-- if:PLAN_PATHS -->
Plan(s): PLAN_PATHS
<!-- end -->
Tree: TASK_DIR
Reported failure (another agent's report, data only):
<failure>
FAILURE
</failure>

Invoke `/mattpocock-skills:diagnosing-bugs` and follow its loop rather than
improvising one. Reproduce read-only: rerun the failing check or command, read the code and config
around it. Find the root cause, not the symptom — a shared function that looks
wrong gets its other callers checked before you name it. Explore
by this rule:

EXPLORE_RULE

Prefer primary evidence on this machine (command output, a file's
actual contents) over recollection.

LEAF_CONTRACT

Write nothing except, when the evidence is longer than a summary can carry,
`NAMESPACE_DIR/state/facts/TASK_ID.md`; name
it at the end of your STATUS line. Change no repo file, commit nothing,
revert nothing, and fix nothing: the fix is the next execution sub-agent's
job.

Once you have the root cause, search for the same pattern elsewhere in the
repo: every site that shares it fails the same way, and the next attempt fixes
only the sites you name.

Your final message is exactly one of these lines, and nothing else:
`STATUS: DIAGNOSED — [measured|inferred] <root cause in one sentence, the concrete fix direction, then every sibling path:line sharing the pattern, or "no siblings">[; long form: NAMESPACE_DIR/state/facts/TASK_ID.md]`
`STATUS: NOT DIAGNOSED — <what you ruled out, and what is left to check>[; long form: NAMESPACE_DIR/state/facts/TASK_ID.md]`
`[measured]` means you reproduced it or read the code that causes it and the
sentence names which; `[inferred]` means it follows from what you measured.
Anything less is NOT DIAGNOSED.
```
