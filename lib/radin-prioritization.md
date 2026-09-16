# Shared: radin-execute Priority Criteria

`radin-execute` reads this file at Phase 1 step 4, and only when
`RADIN_CLI backlog order --rank-needed` exited 0. It holds the two things
`order` cannot compute: how to rank the entries whose `priority` is unset, and
when one entry's body implies a dependency on another's.

## Priority criteria

The order itself is not yours to compose: `RADIN_CLI backlog order` is the
sort, the dependency fix and the report, and each of its modes is used as-is.

```bash
RADIN_CLI backlog order --rank-needed                      # the gate
RADIN_CLI backlog order --report  [--rank <csv>] [--infer-deps <id>=<csv>]...
RADIN_CLI backlog order --steps   [--rank <csv>] [--infer-deps <id>=<csv>]... [--defer <csv>]
```

One rule is left, and it is a rule rather than a computation:

1. **A prioritization pass writes nothing.** Read a task's body only for an id
   `--rank-needed` printed; the title alone is never the task. No
   `set-priority`, no `set-deps`: a set `priority` and a set `depends_on` are
   the human's, used verbatim. Whatever this pass concludes leaves as an
   `order` flag, which validates it, and never as an index write. The
   condition is a priority on every entry, not "both fields set": the CLI
   cannot store an explicitly empty `depends_on`, so an absent one is the
   human's "no dependencies", not a gap to fill.

### Weighted criteria for unset entries (in order of weight)

- **Blocking issues** (bugs that prevent core functionality) → highest priority
- **Security or data-loss risks** → very high priority
- **High-impact features** with clear specifications → high priority
- **Dependency order** (task A must precede task B) → infer one only where
  the index has none, and only within these bounds: one entry's body must
  name a file, symbol or behaviour the *other* entry's body says it will
  **change** (naming the same area is not enough), and at most one inferred
  dependency per entry, the earlier-ranked entry being the dependency. This
  is the one genuinely semantic judgment in the pass — `order` cannot read
  two bodies for overlap — so it stays here, bounded.
- **Effort vs. value** (quick wins with high value) → prefer earlier
- **Nice-to-haves and ideas** → lowest priority

The pass produces two things and nothing else: the unset group in your order,
as `order --rank <csv-of-ids>`, and one `order --infer-deps <id>=<csv>` flag
per entry you inferred a dependency for. No `order` number (`--steps` numbers
them).
