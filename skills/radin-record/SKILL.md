---
name: radin-record
description: |
  Log bugs, follow-ups, ideas or feedback raised this session as backlog
  entries that outlive the conversation. Use for /radin-record or any ask to
  save something for later, even a vague one ("add the findings"): scan the
  whole session.
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

- It cuts a narrow but COMPLETE path through every layer it touches.
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

A ticket key, Jira or GitHub issue URL: fetch it through the MCP if possible,
and treat the ticket as extension to the user's prompt.
No MCP or API access: log from the ask alone, and continue.

## Step 2: Chart each item's open decisions

Settle judgment calls here, while the user is present;

For each item, list what a cold start would have to decide that the conversation
didn't settle. Tag each question:

- **Fact**: checkable against the repo, docs, or an API. Never ask the user for
  these; note each in the entry body as an open fact to verify.
- **Decision**: a judgment call only the user can make (tradeoff, scope boundary,
  behavior choice). Invoke `/mattpocock-skills:grilling` on this item's decisions
  now, before the next item. Keep every settled answer for Step 5's body.

Name even one plausible guess (a threshold, a naming choice, keep-vs-remove) and
the item has a Decision, so grill it. An item with no second reasonable way to do
it skips this step, and so does a stub, one deliberately deferred whole.

If the user defers a question or stops answering, record the question itself as an
open decision in the entry body, options and your recommendation included, so
`radin-batch` blocks on it explicitly instead of guessing.

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

Then judge whether the item needs a plan before execution. It needs none when
the change touches one or two files and has one obvious approach: an
execution sub-agent then implements from the entry alone. Anything else needs
a plan: more files, a new module boundary or data shape, or an approach with a
real alternative.

## Step 5: Review, quiz the user on the batch, then append via the CLI

An entry passes by carrying its decisions, or by naming what stays open. Literal
content in the ask, such as an error string, a path, a snippet or an explicit constraint,
belongs in the `**Raised as:**` quote before anything is appended.

Present the batch as a numbered list, each item showing:

- **Title**: the short descriptive name.
- **Category**: from Step 4.
- **Blocked by**: the entries that gate it, or "None, can start immediately".
- **What it delivers**: the end-to-end behavior this entry makes work.
- **Plan**: needed or not, with the one-line reason.

Then ask whether the granularity, the dependencies, the split and the plan
verdicts are right.
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

For each approved item:

```bash
RADIN_CLI backlog add <category> "<short title>" [--skill <skill-name>] [--acceptance "<criterion>"] [--planning needed] <<'EOF'
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

Pass `--planning needed` on each approved entry whose verdict is "needed".

Once every `add` has printed its id, record Step 4's
dependencies, one call per dependent entry, always after all the adds:

```bash
RADIN_CLI backlog set-deps <dependent-id> <csv-of-ids-it-depends-on>
```

Each noted title is either an id an `add` just printed, or, for a task that already
existed, `RADIN_CLI backlog field "<title>" TASK_ID`.

Always append. Never scan for near-duplicates or merge with an existing entry, because a
false-positive merge silently drops something the user cared about, which is worse
than an occasional repeat.

## Step 6: Report back

**Reply:** how many entries were logged, with titles, categories and plan
flags, and the
backlog path the CLI printed; the decisions grilling settled and the questions
left open, per entry. When nothing in scope rose to a loggable item, say so
plainly and write no vague entry to prove the skill ran.
