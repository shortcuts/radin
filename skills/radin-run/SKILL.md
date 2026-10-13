---
name: radin-run
description: |
  Record one ad-hoc prompt as a backlog entry, then execute just that task.
  Use for /radin-run <prompt>.
disable-model-invocation: true
---
# Run One Prompt

A front door for one piece of work: record it, optionally plan it, run the
loop on that one task.

## Step 1: Record

Invoke `/radin-record` with the user's prompt as a specific ask, plus one
instruction: log exactly one entry, never split it, no dependencies. Record's
slicing check and grilling run; its batch gate is skipped for a one-entry
specific ask. A prompt too big for one slice still gets one entry; tell the
user to use `/radin-record` for large work.

Take the new entry's id from the `add` output. With only a title, run
`RADIN_CLI backlog find "<title>"`.

## Step 2: Plan or implement

Ask with `AskUserQuestion`: `Plan it first` or `Implement directly`.

- Implement directly: go to Step 3.
- Plan it first: invoke `/radin-plan` on the id and plan the entry as one
  unit. Show the user a summary of the plan's Outcome and Decisions, then ask
  with `AskUserQuestion`: `Execute`, `I have feedback`, or `Stop`.
  - `Execute`: go to Step 3.
  - Feedback: invoke `/mattpocock-skills:grilling` on the plan's open
    decisions, revise the plan file in place, show the summary again, and ask
    again. Loop until `Execute` or `Stop`.

**Stop** at any round in Steps 1 and 2: run `RADIN_CLI backlog remove "<id>"`,
report the removal, run nothing.

## Step 3: Run the loop

Read `RADIN_LIB/radin-run.md` in full now and follow it as this skill's body.
Re-read it after any compaction. The invoking scope is the task id from Step 1.

## No-plan rule

Call `task-next` and `task-report --next` with no other flag. Every task then
comes back as `kind execution`, and a task with a plan implements from that
plan.

**Reply:** the run loop's Phase 5 summary, verbatim; or, after a stop, the
removal line from `backlog remove`.
