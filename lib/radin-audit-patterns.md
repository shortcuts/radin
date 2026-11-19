# Prompt audit patterns

Source: Anthropic's `prompt-audit`, `prompt-caching` and `token-counting` notes (`anthropics/skills`, `claude-api/shared`), cut to the patterns that apply to files an agent loads.

**The test:** could the model already know this, or does the sentence change what it does? A sentence that fails both is a cut candidate.

## Keep

- Audience, product, environment, quality bar, tool mechanics, and the reason behind a constraint.
- Exact commands for fragile work (destructive commands, auth, compliance).
- A prohibition whose failure still reproduces on the target model.
- Routing text such as a skill description. It may carry calibrated urgency.
- A format example, labeled as an example.
- Redundancy that works. Propose a merge only when the copies disagree.

## Patterns

| Id | Pattern | Fix |
| --- | --- | --- |
| P1 | Pressure language: dense `MUST`, `NEVER`, `CRITICAL`, `IMPORTANT`, `!!`. | State the rule plainly. Keep the stress only on a hard guardrail. |
| P2 | Hedged requirement: `try to`, `if possible`, `ideally` on a real requirement. | Write the imperative. |
| P3 | Scaffold a model feature replaced: `think step by step`, a scratchpad tag, `plan before acting`, `think harder`. | Delete. Control depth through the effort setting. |
| P4 | Output ceiling or cadence: `under 120 words`, `summarize every N tool calls`, `no interim updates`. | State the audience and goal. Keep a number only where the format needs it. |
| P5 | Choreography for a judgment task: numbered steps where order does not matter. | State outcome, constraints and the check. |
| P6 | Prohibition list: 3 or more `Do not` or `Never` in a row. | Keep the ones that still fail. Rewrite the rest as the target behavior. |
| P7 | Padding: generic virtues, `Remember,`, `Again,`, near-duplicate sentences, a limit with an escape hatch. | Say it once, in the right place. |
| P8 | Grader vocabulary: `graded on`, `hidden tests`, `rubric`. | State the requirement. Leave the grader out. |
| P9 | Strategy coaching: `it is usually best to`. | Delete unless it changes what is legal or how success is measured. |
| P10 | Fossil: a workaround for a retired model, a `known issue` note, a `before` or `after` date, a retired model name. | Trace it to the model it patched. Remove it when that model is gone. |
| P11 | Tool discouragement: `only use tools when necessary`, `minimize tool calls`. | Delete. Say when a source should be checked first. |
| P12 | Unreasoned style ban: `never use bullets`, `do not start with "Certainly"`. | Add the reason, or write the wanted style as a conditional rule. |
| P13 | History narrative: an incident id, a PR number, a pinned model name. | State the current rule. Drop the story. |
| P14 | Unenforced rule: nothing checks it and transcripts show it broken. | Enforce it in code or delete it. |
| P15 | Patch accretion: many narrow conditionals, each from one incident. | Write the one principle. |
| P16 | Verbose skill or rule file. | Apply the test paragraph by paragraph. |
| P17 | Wrong degrees of freedom: prose where a fragile command needs the exact text, or an exact script where judgment fits. | Match the form to the risk. |
| P18 | Volatile specific: a hard-coded path, flag, version or count. | Check it against the repo. A claim the repo contradicts is high confidence. |
| P19 | Conflict between two loaded files. | Quote both. `git blame` orders them, never file times. Rewrite the older to match. Flag it when the older is a safety rule or history cannot order them. |
| P20 | Trigger-case list in a skill description. | Name the intent in general terms. |
| P21 | Dead weight in the always-loaded set: reference text that one task needs. | Move it behind a skill or a path-scoped rule. Load it on demand. |

## Cache hazards

The loaded files form the start of every request. A caching prefix matches byte for byte, so one changed byte invalidates everything after it.

- **Volatile text early.** A date, branch name, count, generated table or session id in an always-loaded file changes the prefix. Move it to the end, make it deterministic, or delete it.
- **Content that varies per user or machine** (a user path, an installed-tool list) ahead of stable text.
- **Order.** Put text that never changes first, text that changes per project next, text that changes per task last.
- **Small prefix.** A prefix under the model's minimum (512 tokens on the newest models, up to 4,096 on older ones) does not cache. Do not pad a file to reach it.
- **Edit cost.** An edit to an early line re-writes the cache for the rest of the prefix. Batch edits to always-loaded files.

## Report entry

One entry per finding:

- **Where:** `file:line`.
- **Evidence:** the exact quote.
- **Pattern:** the id from the table.
- **Why:** one or two sentences.
- **Confidence:** High (contradicted by the repo, or documented), Medium (seen to fail), Low (heuristic, flag only).
- **Action:** remove, rewrite, move, merge or flag.
- **Saves:** estimated tokens.

Sort by confidence, then by tokens saved. A finding with no hit on any pattern is not a finding.
