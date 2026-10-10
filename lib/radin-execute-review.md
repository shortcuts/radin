# Shared: radin-execute Review

`radin-execute` reads this file at Phase 6, only when the user asked for a
post-session review.

Reviewer sub-agent (`model: "RADIN_MODEL_REVIEW"`). The
`radin-review` skill already owns the review-and-log flow, so send exactly:

```
You run non-interactively: you cannot reach the user and have no
`AskUserQuestion`, so take each non-destructive branch the skill names.

Invoke the `/radin-review` skill with scope: the commit(s) made this session
(<list of commit hashes recorded in Phase 4>), plus any review instructions
from the invoking prompt: <instructions, or "none">.
```
