---
name: radin-execute
description: |
  Work through a project's whole backlog: prioritize every task, execute each
  via a sub-agent, commit after each. Use when the user wants the entire
  backlog processed ("work through my backlog"), not one named task.
  Delegates all implementation to sub-agents; clarifies ambiguity by asking
  the user rather than guessing.
---
# Backlog Execution

Read `RADIN_LIB/radin-run.md` in full now and follow it as this skill's body.
Re-read it after any compaction.

## No-plan rule

Step 4a applies this rule to a task with no plan: delegate planning —
unconditionally, with no judgment of the task's size or shape. Planning
happens here, one task before its own execution dispatch, so the plan is
written against the tree the previous tasks' commits already left behind, and
the plan file it leaves on disk is the whole handoff:

```bash
RADIN_CLI prompt planning "<task id>"
```

It prints `model<TAB><name>`, a `--- prompt ---` line, then the prompt. Send
everything after that line as one `Task` call with exactly that model.
Substitute nothing and add nothing: the CLI assembled it.

- `STATUS: PLANNED`: proceed to Step 4b.
- `STATUS: BLOCKED (FACT|DECISION)`: route per Clarifying Ambiguity, then
  retry Step 4a.
