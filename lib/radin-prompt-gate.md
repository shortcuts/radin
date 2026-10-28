# Template: radin-batch session gate prompt (Phase 4.5)

Rendered by `radin prompt gate`. `lib/radin-prompt.sh` holds the format. The
`GATE_REVIEW` block drops once `radin state gate-filed` marks the session's
one review round used.

`model: "RADIN_MODEL_EXECUTION"`

`effort: "RADIN_EFFORT_EXECUTION"`

```
Run this repo's lint and format checks, as its own docs or CI config define
them, `rtk`-wrapped. Skip the test suite: each task already ran the tests its
diff reached. Run the checks once at the tip of each branch listed below, in
the worktree on its line. Write nothing under `.claude/.radin/` by hand, and
leave each checkout on the branch it started on.
LEAF_CONTRACT

The session's branches, one per line: branch, tip, worktree, oldest session
commit, TAB-separated.
GATE_MAP

Red: fix forward on that branch through `/caveman:surgical-patch`, commit
through `/caveman:caveman-commit`, and re-run the checks. Leave the tree clean.

<!-- if:GATE_REVIEW -->
Review: once the checks are green, read RADIN_LIB/radin-review-core.md and
follow it at level session, one branch line at a time. The scope of a line is
`<oldest session commit>^..<tip>`, your fix commits included. Invoke each pass
yourself.

Pipe every finding line through `RADIN_CLI scope --bucket`. Drop each
`consider` and `noted` line. File each `act-on` line as one backlog entry, `fix`
for incorrect behavior and `refactor` for the rest:

RADIN_CLI backlog add <fix|refactor> "<short title>" --location "<path:line>" [--planning needed] [--complexity low|high] <<'EOF'
**Finding:** <the line, opened with the spec line it quotes>
**Severity:** <critical|warning|nit>
**Evidence:** <rung> — <the reasoning or output>
**Preferred remedy:** <the concrete change>
EOF

Pass `--planning needed` unless this rule says the entry needs no plan:
PLANNING_RULE

Size an entry with no `--planning needed` by this rule and pass
`--complexity <low|high>`:
COMPLEXITY_RULE

File a failing check you could not fix the same way, as a `fix` entry. Each
entry you file is one id in the final line's `filed` list.
<!-- end -->

Your final message is exactly one of these lines, and nothing else:
`STATUS: SUCCESS — <"checks green at <hash>", or "fixed in <hash(es)>">`
`STATUS: FAILED — <failing check>, <why no fix landed>`
`STATUS: INCONCLUSIVE — <check that could not run, and why>`
<!-- if:GATE_REVIEW -->
When you filed entries, end a SUCCESS or FAILED line with `; filed <id>,<id>`.
<!-- end -->
```
