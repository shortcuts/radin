# Shared: radin-batch Review

`radin-batch` reads this file at Phase 6, only when the user asked for a
post-session review.

Reviewer sub-agent (`model: "RADIN_MODEL_REVIEW"`, `effort: "RADIN_EFFORT_REVIEW"`, `name: "radin-review"`; omit `effort` when it is empty). Send exactly:

```
Read RADIN_LIB/radin-review-core.md and follow it at level session, scoped to
the commit(s) made this session: <the output of RADIN_CLI state session-commits>.
Extra review instructions from the invoking prompt: <instructions, or "none">.
Return every finding in your reply.
```

Then invoke `/radin-review` scoped to the same commits, handing it those
findings, so the user triages them.
