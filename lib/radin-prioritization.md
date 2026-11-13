# Shared: radin-batch Priority Criteria

`radin-batch` reads this file at Phase 0, and only when
`RADIN_CLI state preflight` printed a `rank` line. It holds the two things
`order` cannot compute: how to rank the entries whose `priority` is unset, and
when one entry's body implies a dependency on another's.

## Read the unset entries

Run `RADIN_CLI backlog list --unset-priority --meta` once. Each row holds the
id, category, title, file, depends-on csv and meta lines, such as acceptance
and location, of one unset entry. Rank from these rows. Read a body with
`RADIN_CLI backlog field "<id>" TASK_BODY` only to confirm a dependency two
rows suggest.

## A prioritization pass writes nothing

No `set-priority`, no `set-deps`. A set `priority`, a set `depends_on` and an
epic's `depends_on` come from the human or `radin-record`, used verbatim. The pass leaves only as `order` flags, which
validate it. An absent `depends_on` is the human's "no dependencies", not a
gap to fill: the CLI cannot store an explicitly empty one.

### Weighted criteria for unset entries (in order of weight)

- **Blocking issues** (bugs that prevent core functionality): highest priority
- **Security or data-loss risks**: very high priority
- **High-impact features** with clear specifications: high priority
- **Dependency order** (task A must precede task B): infer one only where
  the index has none, and only within these bounds: one entry's body must
  name a file, symbol or behaviour the *other* entry's body says it will
  **change** (naming the same area is not enough), and at most one inferred
  dependency per entry, the earlier-ranked entry being the dependency.
- **Effort vs. value** (quick wins with high value): prefer earlier
- **Nice-to-haves and ideas**: lowest priority

The pass produces two things and nothing else: the unset group in your order,
as `order --rank <csv-of-ids>`, and one `order --infer-deps <id>=<csv>` flag
per entry you inferred a dependency for. No `order` number (`--steps` numbers
them).
