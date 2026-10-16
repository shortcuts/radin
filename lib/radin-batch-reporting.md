# Shared: radin-batch Final Summary

`radin-batch` reads this file at Phase 5.
`RADIN_CLI state report`
prints the report itself: the residual-changes check, the commit-location
lines with what each task built, chose and left open, every `failed`, `blocked` and `deferred` entry with its note, the
stashes this session created, the skills `task-next` dropped as
unrunnable by a sub-agent, and the out-of-plan files per task. One thing it cannot do:

- `RADIN_CLI backlog duplicates` finds the duplicate ids and titles manual
  edits leave behind. Exit 0: flag its output in the summary rather than
  guessing which copy to remove. Exit 1: nothing to say.
