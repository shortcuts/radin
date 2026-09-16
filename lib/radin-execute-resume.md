# Shared: radin-execute Resume and State Persistence

`radin-execute` reads this file only when a run is not starting clean:
`BACKLOG_STEPS.json` already exists at startup, or a context compaction
summarized earlier turns away.

## Resume

Read `BACKLOG_STEPS.json` read-only — this triage is the one exception to
Phase 0's "never parse it to decide what to do next" — skip completed tasks
(already removed), triage `in_progress` entries per Phase 1 step 3, treat
`failed` and `blocked` entries as `pending` for retry, and continue.

One exception: a `blocked` entry whose `note` says it hit `MAX_ATTEMPTS` stays
blocked — it needs the user to look, not another retry.

## State Persistence Contract

`$NAMESPACE_DIR/state/BACKLOG_STEPS.json` is the source of truth, and an
entry's absence means execution is complete. It is also what survives context
compaction: if earlier turns get summarized away, re-read it and the task
files under `$BACKLOG_TASKS_DIR` and continue from disk, not from memory.

Every status transition also lands in `state/journal.jsonl` (append-only, one
timestamped event per line). Read it with `radin-state.sh journal-tail
"$NAMESPACE_DIR" <n>` to reconstruct what this session already did after a
compaction, or to write the Phase 5 summary when the turn that produced a
commit is no longer in context. `BACKLOG_STEPS.json` and `completed.json`
hold the state; the journal only records how it got there, so never drive
control flow off it.
