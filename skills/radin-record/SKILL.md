---
name: radin-record
description: |
  Use for /radin-record or any ask to save something for later, even a vague
  one ("add the findings"): scan the whole session. Logs bugs, follow-ups,
  ideas or feedback raised this session as backlog entries that outlive the
  conversation.
---
# Record to Backlog

## Step 1: Decide what to log

The instruction sets the scope:

- **Specific**: "add the auth timeout bug", "fix this issue", "work on adding that feature"
- **Generic**: "add the findings", "record everything", "we should probably": scan the whole
  session for anything a reasonable person calls a bug, follow-up, idea, or feedback.
  Each distinct item becomes its own entry.

Log the entry worded close to how it was raised.

One raised thing can be several sequential pieces of work ("add rate limiting on
top of new auth middleware" needs the middleware first). Log each piece as its
own entry, sized as a **vertical slice**:

- It cuts a narrow but complete path through every layer it touches.
- Landed, it is demoable or verifiable on its own.
- It fits one fresh context window.
- A **prefactor**, the restructuring that makes the real change easy, is its
  own entry, which every entry needing it depends on.

One mechanical change whose blast radius fans across the codebase is the exception,
so log it as one entry per batch the change breaks, plus a final
entry that puts the tree back green depending on every batch.

An item too fuzzy to phrase as a sharp question is a **stub** ("figure out
caching at some point"): log one stub over the whole area, its body saying what
is unspecified and what is known, rather than pre-slicing it. Step 2
sharpens it later. A question you *can* state precisely is an ordinary entry,
blocked or not.

### An external ticket as context (optional)

A ticket key, Jira or GitHub issue URL: fetch it through its MCP,
and treat the ticket as extension to the user's prompt.
No MCP or API access: log from the ask alone, and continue.

## Step 2: Chart each item's open decisions

Settle judgment calls here, while the user is present.

Apply `RADIN_LIB/radin-open-decisions.md` to each item. Note each Fact in the entry
body as an open fact to verify. Ask the item's Decisions now, before the next item
and before Step 5's batch list. Keep every settled answer for Step 5's body. An
item with no Decision asks nothing, and so does a stub, one deliberately deferred
whole.

Pick the channel by the Decisions:

- **Up to 4 Decisions, each with discrete options:** one `AskUserQuestion` call.
  Put your recommendation first, marked "(Recommended)".
- **More than 4, open-ended answers, or answers that depend on each other:** invoke
  `/mattpocock-skills:grilling` on them.

**The test:** does Step 5's list show a question for the user to answer? Then it
belongs here. Step 5 asks only whether the split, the dependencies and the plan
verdicts are right.

If the user defers a question or stops answering, record it as one body line,
`**Open decision:** <question>, <options>, <your recommendation>`, so
`radin-batch` asks it before execution instead of guessing.

## Step 3: Note any skill invoked for this item

If the request that raised the item explicitly invoked a skill (e.g.
`/radin-record /frontend-design make the accent color...`, or a skill ran earlier
and the item continues that work), record it as a standing instruction, even if it
looks redundant or wrong-fit to you: without the line a cold start re-implements
from bare text and never invokes the skill the user chose.

`/radin-record /other-skill <...>` means "record an instruction to run
`/other-skill` later", and never run `/other-skill` now. Treat `/other-skill
<...>` as the text to log: go to Step 1 with it as the item, log with
`--skill other-skill`, and stop.

## Step 4: Classify each item and note dependencies

Does landing this item require another item in the batch (or an existing backlog
task) to land first, by sharing a file/function/behavior or by an explicit
build-on? Note the other entry's exact title for Step 5's `set-deps`, and say why
it comes first in the dependent entry's description. The `depends_on` field
carries the ordering, the prose the reason.

Classify into exactly one category (conventional-commit vocabulary):

- **feat**: a new capability asked for (idea, feature request).
- **fix**: something broken or behaving incorrectly.
- **chore**: a maintenance follow-up (docs, tooling, cleanup).
- **refactor**: structure should change without behavior change.

Then group. Two or more items in the batch that serve one feature, goal or
raised thing form an **epic**. Run `RADIN_CLI backlog epics` first. When an existing
epic already covers the goal, reuse it. A lone item gets no epic.

**The test:** would each body repeat the same background, the same `**Raised as:**`
quote or the same constraint? Then it belongs in the epic.

Then judge whether the item needs a plan before execution. Judge by `RADIN_LIB/radin-planning-rule.md`. An entry that needs no plan goes to an execution sub-agent, which implements from the entry alone.

Size each entry that needs no plan by `RADIN_LIB/radin-complexity-rule.md`. The
planner sizes an entry that needs a plan.

## Step 5: Review, quiz the user on the batch, then append via the CLI

An entry passes by carrying its decisions, or by naming what stays open. Literal
content in the ask, such as an error string, a path, a snippet or an explicit constraint,
belongs in the `**Raised as:**` quote before anything is appended.

Present the batch as a numbered list, each item showing:

- **Title**: the short descriptive name.
- **Category**: from Step 4.
- **Blocked by**: the entries that gate it, or "None, can start immediately".
- **What it delivers**: the end-to-end behavior this entry makes work.
- **Plan**: needed or not, with the one-line reason. When not needed, the complexity.

Show each epic once above its items: its slug, and the shared context it will hold.

Then call `AskUserQuestion` with one question: "Are the granularity, the dependencies,
the split and the plan verdicts right?" Offer two options, "Yes, log them
(Recommended)" and "No, I want changes". Never ask this as plain text.

**Why:** a plain-text question scrolls past, and a user who closes the window logs nothing.

On "No", ask what to change, revise the list, and call `AskUserQuestion` again.
Iterate until the user approves the batch. One run skips the gate: a specific ask
that produced exactly one entry with no dependencies. A generic ask always
quizzes, single entry included, because a session scan is a guess about what the
user wants captured.

A cold start reads the body and nothing else, so quote rather than paraphrase.
Your paraphrase is the only version that survives. Name the behavior and each
file by its role, because the paths and snippets you would write yourself go
stale within a commit or two. Two exceptions stay verbatim: the `**Raised as:**`
quote, paths and snippets the user pasted included, and a snippet that encodes a
decision more precisely than prose can (state machine, schema, type shape),
trimmed to the decision-rich part.

For each new epic, create it before its items. The description holds the shared
context: what was being worked on, why it matters, the `**Raised as:**` quote, and
any `**Decision:**` line that applies to every child. A child inherits it, so a
child body keeps only what is specific to that entry.

```bash
RADIN_CLI backlog epic-add <epic-slug> <<'EOF'
<the shared context>
EOF
```

For each approved item:

```bash
RADIN_CLI backlog add <category> "<short title>" [--skill <skill-name>] [--acceptance "<criterion>"] [--planning needed] [--complexity low|high] <<'EOF'
<the description: what was being worked on, the item close to how the user
stated it, why it matters>

<**Raised as:** and the triggering text verbatim, the user's words plus any
error string, path or snippet they pasted.>

<one **Decision:** <question -- settled answer> line per Step 2 answer, then any
open facts or deferred decisions in plain prose.>
EOF
```

Each `add` prints the bare id on stdout.

Pass Step 3's skill(s) as `--skill <skill-name>` (repeatable). The CLI composes
the canonical instruction sentence itself; never write it by hand. Omit the
flag when no skill applies.

Acceptance criteria live on the entry, not in the body: pass each criterion the
session already stated as `--acceptance "<criterion>"` (repeatable), as bare text
with no bullet and no checkbox. Never ask for criteria, never synthesise one.

Pass `--planning needed` on each approved entry whose verdict is "needed", and
`--complexity <low|high>` on every other entry.

Once every `add` has printed its id, file each child under its epic, one call per child:

```bash
RADIN_CLI backlog epic-move <id> <epic-slug>
```

Then record Step 4's
dependencies, one call per dependent entry, always after all the adds:

```bash
RADIN_CLI backlog set-deps <dependent-id-or-title> <csv-of-ids-or-titles-it-depends-on>
```

Each item is an id an `add` just printed, or the title of a task that already
existed. A title that matches several entries fails the call. Pass its id instead.
A new entry whose dependencies all exist may pass `--deps <csv-of-ids-or-titles>`
on its `add` instead.

Always append. Never scan for near-duplicates or merge with an existing entry, because a
false-positive merge silently drops something the user cared about, which is worse
than an occasional repeat.

## Step 6: Report back

**Reply:** how many entries were logged, with titles, categories, plan
flags and epic, and the
backlog path the CLI printed; the decisions grilling settled and the questions
left open, per entry. When nothing in scope rose to a loggable item, say so
plainly and write no vague entry to prove the skill ran.
