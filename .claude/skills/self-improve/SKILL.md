---
name: self-improve
description: Use for /self-improve. Measures the context radin loads and ranks what to trim.
disable-model-invocation: true
---
# Measure radin's context

## Step 1: Measure

Run both from the repo root. `cargo run -q --` makes the build under test answer, not the installed binary.

1. `cargo run -q -- context` prints the static budget of each host render. Its tables cover always-loaded tokens, each skill's route (body plus every lib file it names) and each lib file with the routes that name it.
2. `cargo run -q -- stats --no-repos --no-companions --since <date>` prints the measured load. Read `radin context load` (skills, lib files, `radin prompt` renders, sub-agent reports) and `radin roles` (tokens per sub-agent role). Use the date the user names, else omit `--since`.

Measured numbers run about twice the static ones, because a `Read` adds line numbers. Compare items with each other, never one table with the other.

Done when both outputs are on screen and every table has at least one row. An empty `radin context load` means no transcripts matched: say so and stop.

## Step 2: Rank

Each hit is a candidate. Record its number, not a verdict.

- **Near the ceiling.** An always-loaded or route total within 10% of `ALWAYS_CEILING` or `ROUTE_CEILING` in `src/context.rs`.
- **Named by most routes.** A lib file that more than half the routes name.
- **Paid twice.** A lib file or skill whose `loads` exceeds its `sessions`.
- **Heavy render.** A `prompt <kind>` or `agent radin-<role> report` row above 1,000 tokens on average.
- **Costly role.** The `radin roles` rows with the highest `avg-tokens`.

Done when every table row has passed through each test.

## Step 3: Trace

Open each candidate's source in full: `skills/<name>/SKILL.md`, `lib/<file>`, or `src/prompt.rs` for a render. Apply `/mattpocock-skills:writing-for-agents`: disclose reference behind a pointer, keep one source per meaning, drop what the environment already holds.

**The test:** would deleting this sentence change what the agent does? Name each sentence that fails it, with its file and line.

Done when every candidate has either named lines to cut or a one-line reason it stays.

## Step 4: Report

Edit nothing. Rank the candidates by tokens saved: each with its number, its source lines and its proposed cut. A table with no hit gets "nothing to trim", with its totals.

For each entry the user keeps, run `/radin-record`. Once a cut lands, run Step 1 again, compare, and set the ceiling in `src/context.rs` to the new total plus 8%. A prose edit that claims to change behavior follows "Measure a prose edit" in `CONTRIBUTING.md`.

**Reply:** the ranked list, then the two totals that frame it: always-loaded tokens per host and `all radin items` as a share of context growth.
