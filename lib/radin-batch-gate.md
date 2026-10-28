# Shared: radin-batch Session Gate

`radin-batch` reads this file at Phase 4.5, once per session that recorded a commit, and once more after a review round.

Run `RADIN_CLI prompt gate`. Exit 1 means the session has no commit: skip the gate. Otherwise dispatch one sub-agent (`name: "radin-gate"`, the printed `model` and `effort`, when printed) with `Read <the printed prompt path> and follow it.`

Run `RADIN_CLI state gate-fix <hash>...` for every hash after `fixed in` in a `STATUS: SUCCESS` line.

Run `RADIN_CLI state gate-filed <id>...` for every id after `filed` in a `SUCCESS` or `FAILED` line. Exit 0: the entries are `pending` steps, so go back to Phase 4. When the loop exits again, run this gate once more. That second prompt holds no review, so the loop ends there. Exit 1: the review round is used already, so give the ids to the user after the Phase 5 summary.

A `FAILED` or `INCONCLUSIVE` line with no `filed` list, or a last line that is not a `STATUS:` line, goes to the user after the Phase 5 summary, verbatim.
