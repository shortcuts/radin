---
name: radin-implement
description: |
  Implement backlog tasks via sub-agents with no planning pass, prioritized,
  one commit each. Use for "skip planning", "just implement the backlog", or
  name an epic or task to run only those. A task with a plan still follows it.
---
# Backlog Implementation

Read `RADIN_LIB/radin-run.md` in full now and follow it as this skill's body.
Re-read it after any compaction.

## No-plan rule

Call `task-next` and `task-report --next` with no other flag. Every task then comes back as `kind execution`,
whatever its size or shape, and a task with no plan implements from the entry
text alone.
