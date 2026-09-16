# Shared: radin-execute Final Summary

`radin-execute` reads this file at Phase 5, once the execution loop has
exited. `RADIN_CLI state report "$NAMESPACE_DIR" [<dropped-skill line>...]`
prints the report itself — the residual-changes check, the commit-location
lines, every `failed`, `blocked` and `deferred` entry with its note, and the
stashes this session created. Two things it cannot do:

- Each extra argument becomes one bullet under `Skills dropped as unrunnable
  by a sub-agent`, so pass one per skill Step 4b dropped, shaped
  `<task title> — <skill>: asks the user or spawns its own agent.` No
  arguments, no such block.
- `RADIN_CLI backlog duplicates` finds the duplicate ids and titles manual
  edits leave behind. Exit 0: flag its output in the summary rather than
  guessing which copy to remove. Exit 1: nothing to say.
