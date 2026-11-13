---
name: radin-record
description: |
  Use for /radin-record or any ask to save something for later, even a vague
  one ("add the findings"): scan the whole session. Logs bugs, follow-ups,
  ideas or feedback raised this session as backlog entries that outlive the
  conversation.
argument-hint: "[what to log]"
---
# Record to Backlog

## Step 1: Decide what to log

The instruction sets the scope:

- **Specific**: "add the auth timeout bug", "fix this issue", "work on adding that feature"
- **Generic**: "add the findings", "record everything", "we should probably": scan the whole
  session for anything a reasonable person calls a bug, follow-up, idea, or feedback.
  Each distinct item becomes an entry, or joins one by the size rule below.

Log the entry worded close to how it was raised.

One raised thing can be several sequential pieces of work ("add rate limiting on
top of new auth middleware" needs the middleware first). Log each piece as its
own entry, sized as a **vertical slice**:

- It cuts a narrow but complete path through every layer it touches.
- Landed, it is demoable or verifiable on its own.
- It fits one fresh context window.
- It is worth a leaf. A leaf pays the same planning, checks and review whatever
  its diff size, so a piece one function or one small diff covers joins the
  piece that touches the same module.
- A **prefactor**, the restructuring that makes the real change easy, is its
  own entry, which every entry needing it depends on, when it is a slice on its
  own. A small prefactor opens the entry that needs it.

**The test:** would two leaves read the same files, and could one commit carry
both? Yes: one entry. A piece that changes behavior another piece creates is
part of that piece's entry, never a dependent entry.

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

Apply `RADIN_LIB/radin-open-decisions.md` to each item. Look up every Fact first, in the
repo, its docs or the API, and keep each answer for Step 5's body. Then settle the
item's remaining Decisions now, before the next item and before Step 5's list. Keep
every settled answer for Step 5's body. An item with no Decision asks nothing, and so
does a stub, one deliberately deferred whole.

**Why:** `radin-batch` cannot ask mid-run, so every question left in an entry stalls
that run. The user is present now and the batch is not.

**The test:** can one question per Decision settle it, with no scope left to define?
Yes: the clear-prompt channel below. No: the grilling channel.

Pick the channel for the remaining Decisions. Take the first match:

- **The prompt is vague, the task is complex, or the answers are open-ended or depend on
  each other, or there are more than 4 Decisions:** invoke `@@skill:grilling@@` on them.
<!-- host:claude -->
- **The prompt is clear and up to 4 Decisions each have discrete options:** one
  `AskUserQuestion` call. Put your recommendation first, marked "(Recommended)".
<!-- /host -->
<!-- host:agents -->
- **The prompt is clear and up to 4 Decisions each have discrete options:** one ask per
  `RADIN_LIB/radin-ask-rule.md`.
<!-- /host -->
- **No Decision remains after the Fact lookups:** ask nothing.

**The test:** does Step 5's list show a question for the user to answer? Then it
belongs here. Step 5 asks only whether the split, the dependencies and the plan
verdicts are right.

A Decision stays open only when the user says "later" or does not answer, or when
no user is present to ask (a sub-agent runs this skill). Then record it as one body line,
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

Run `RADIN_CLI backlog show` and read the open entries before you classify. It
prints every entry with its epic. Find the entries each item shares a
file, function or behavior with, and the entries it builds on. An item that
passes Step 1's test against an **open** entry, one whose `RADIN_CLI backlog meta`
prints no `plan` line, joins that entry: Step 5 appends it there. Against any
other entry the item stays its own entry, ordered or related as below.

Does landing this item require another item in the batch (or an existing backlog
task from that read) to land first, by sharing a file/function/behavior or by an
explicit build-on? Note the other entry's exact title for Step 5's `set-deps`, and say why
it comes first in the dependent entry's description. The `depends_on` field
carries the ordering, the prose the reason.

**Place each entry in the global order.** Run `RADIN_CLI backlog order --report`
once and read where each item lands. Pick each new entry's priority from
`1 2 3 5 8 13 21` (higher runs first), so it runs after what it builds on and
before what builds on it. An existing entry whose slot the new entries make wrong
gets a new priority or new deps too. Its text stays as it is.

**An epic depends on an epic** when no child of it can start before the other
epic lands. Note the pair for Step 5's `epic-set-deps`. An epic edge orders every
child after every task of the other epic, so a single child that builds on a single
task takes a task `set-deps` instead.

An entry that relates to an existing task without ordering it gets one body line,
`**Related:** <exact title>, <why they touch>`, so a later run sees the link.

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

## Step 5: Append via the CLI

**Append right away.** Never ask the user to approve the granularity, the
dependencies, the split or the plan verdicts. Step 6 reports them, and
`radin backlog` edits a wrong entry afterwards.

**Why:** a confirmation gate stalls a capture the user already asked for, and a
user who closes the window logs nothing.

An entry carries its decisions, or names what stays open. Literal content in the
ask, such as an error string, a path, a snippet or an explicit constraint, belongs
in the `**Raised as:**` quote before anything is appended.

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

<one **Decision:** <question -- settled answer> line per Step 2 answer, one
**Fact:** line per Step 2 lookup, then any deferred decision as an **Open decision:**
line.>
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

Then record Step 4's epic dependencies and priorities, for the new entries and for
each existing entry Step 4 moved:

```bash
RADIN_CLI backlog epic-set-deps <epic-slug> <csv-of-epic-slugs-it-depends-on>
RADIN_CLI backlog set-priority <id-or-title> <1|2|3|5|8|13|21>
```

`epic-set-deps` replaces the epic's whole list, so pass the old epics with the new.
Run `RADIN_CLI backlog order --report` again. A `dependency override:` line that names
an entry you touched means a dependency has a lower priority than its dependent.
Raise the dependency or lower the dependent, and rerun until no such line remains.

Each item is an id an `add` just printed, or the title of a task that already
existed. A title that matches several entries fails the call. Pass its id instead.
A new entry whose dependencies all exist may pass `--deps <csv-of-ids-or-titles>`
on its `add` instead.

For an item that joins an open entry (Step 4), append its body under its own
heading instead of an `add`:

```bash
RADIN_CLI backlog append <id> <<'EOF'
### <short title>
<the body, as for add>
EOF
```

Then pass the entry's old and the item's new criteria in one
`RADIN_CLI backlog set-meta <id> acceptance <criterion>...`, because the call
replaces the list. An item whose verdict is "needed" also gets
`RADIN_CLI backlog set-meta <id> planning needed`.

Only append to an existing entry. Never remove one or rewrite its text, because
a wrong join must lose nothing the user cared about.

## Step 6: Report back

**Reply:** how many entries were logged and which items joined an open entry,
with titles, categories, plan flags, priority and epic; each epic dependency added;
each existing entry whose priority or deps changed, old and new value; and the
backlog path the CLI printed; the decisions grilling settled and the questions
left open, per entry. When nothing in scope rose to a loggable item, say so
plainly and write no vague entry to prove the skill ran.
