---
name: radin-batch
description: |
  Work backlog tasks via sub-agents, prioritized, one commit each; asks whether
  to plan each task first. Use for "work through my backlog", "skip planning",
  or name an epic or task to run only those.
---
# Backlog Batch

## Step 1: Plan or implement

Ask with one `AskUserQuestion`: `Plan each task first` or `Implement
directly`. Skip the question when the invoking prompt already says which
("skip planning", "just implement").

## Step 2: Run the loop

Read `RADIN_LIB/radin-run.md` in full now and follow it as this skill's body.
Re-read it after any compaction.

## No-plan rule

Step 1's answer sets one flag for every `task-next` call and every
`task-report --next` call.

- `Plan each task first`: pass `--plan-first`. A task with no plan then comes
  back as `kind planning`: delegate planning —
  unconditionally, with no judgment of the task's size or shape. Planning
  happens here, one task before its own execution dispatch, so the plan is
  written against the tree the previous tasks' commits already left behind, and
  the plan file it leaves on disk is the whole handoff. Dispatch its prompt
  like any other.
  - `STATUS: PLANNED`: re-run `task-next --plan-first "<task id>"`, which now hands out the execution prompt.
  - `STATUS: BLOCKED (FACT|DECISION)`: route per Clarifying Ambiguity, then
    re-run the task.
- `Implement directly`: pass no flag. Every task then comes back as
  `kind execution`, whatever its size or shape, and a task with no plan
  implements from the entry text alone. A task with a plan still follows it.

**Reply:** the run loop's Phase 5 summary, verbatim; nothing is skill-specific.
