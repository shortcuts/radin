# Shared: radin-batch Session Gate

`radin-batch` reads this file at Phase 4.5, once per session that recorded a commit.

Run `RADIN_CLI prompt gate`. Exit 1 means the session has no commit: skip the gate. Otherwise dispatch one sub-agent (`name: "radin-gate"`, the printed `model`) with `Read <the printed prompt path> and follow it.`

Run `RADIN_CLI state gate-fix <hash>...` for every hash after `fixed in` in a `STATUS: SUCCESS` line. A `FAILED` or `INCONCLUSIVE` line, or a last
line that is not a `STATUS:` line, goes to the user after the Phase 5 summary,
verbatim.
