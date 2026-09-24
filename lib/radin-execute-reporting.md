# Shared: radin-execute Final Summary

`radin-execute` reads this file at Phase 5.
`RADIN_CLI state report`
prints the report itself — the residual-changes check, the commit-location
lines, every `failed`, `blocked` and `deferred` entry with its note, the
stashes this session created, and the skills `task-next` dropped as
unrunnable by a sub-agent. One thing it cannot do:

- `RADIN_CLI backlog duplicates` finds the duplicate ids and titles manual
  edits leave behind. Exit 0: flag its output in the summary rather than
  guessing which copy to remove. Exit 1: nothing to say.
