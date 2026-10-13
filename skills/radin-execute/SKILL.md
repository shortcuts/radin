---
name: radin-execute
description: |
  Plan and execute backlog tasks via sub-agents, prioritized, one commit each.
  Use for "work through my backlog", or name an epic or task to run only
  those. Asks the user when an entry is ambiguous.
---
# Backlog Execution

Read `RADIN_LIB/radin-run.md` in full now and follow it as this skill's body.
Re-read it after any compaction.

## No-plan rule

Pass `--plan-first` to every `task-next` call and every `task-report --next` call. A task with no plan then comes
back as `kind planning`: delegate planning —
unconditionally, with no judgment of the task's size or shape. Planning
happens here, one task before its own execution dispatch, so the plan is
written against the tree the previous tasks' commits already left behind, and
the plan file it leaves on disk is the whole handoff. Dispatch its prompt
like any other.

- `STATUS: PLANNED`: re-run `task-next --plan-first "<task id>"`, which now hands out the execution prompt.
- `STATUS: BLOCKED (FACT|DECISION)`: route per Clarifying Ambiguity, then
  re-run the task.
