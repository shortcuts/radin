# Shared: radin-execute Resume and State Persistence

`radin-execute` reads this file only when a run is not starting clean:
`BACKLOG_STEPS.json` already exists at startup, or a context compaction
summarized earlier turns away.

## Resume

```bash
RADIN_CLI state steps-list
```

It prints one `id<TAB>order<TAB>status<TAB>attempts<TAB>note` line per entry
still in the plan; completed tasks are already gone. Triage `in_progress`
entries per Phase 1 step 3, treat `failed` and `blocked` entries as `pending`
for retry, and continue.

One exception: a `blocked` entry whose `note` says it hit `MAX_ATTEMPTS` stays
blocked — it needs the user to look, not another retry.

## State Persistence Contract

`.claude/.radin/state/BACKLOG_STEPS.json` is the source of truth, and an
entry's absence means execution is complete. It is also what survives context
compaction: if earlier turns get summarized away, run `RADIN_CLI state
steps-list` and continue from disk, not from memory. Task bodies stay unread:
the router works from ids, titles and status, and each sub-agent reads its own
task.

Every status transition also lands in `state/journal.jsonl` (append-only, one
timestamped event per line). Read it with `RADIN_CLI state journal-tail <n>` to reconstruct what this session already did after a
compaction, or to write the Phase 5 summary when the turn that produced a
commit is no longer in context. `BACKLOG_STEPS.json` and `completed.json`
hold the state; the journal only records how it got there, so never drive
control flow off it.
