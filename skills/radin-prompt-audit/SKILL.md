---
name: radin-prompt-audit
description: |
  Use for /radin-prompt-audit. Measures the context agents load in this repo
  and audits it for dated, redundant or cache-hostile text.
<!-- host:claude -->
disable-model-invocation: true
<!-- /host -->
---
# Audit the loaded context

## Step 1: Measure

Run from the repo root.

1. `radin context --repo` lists every file a session loads here, with its `@imports` and the name and description of each skill. It covers the project (the working directory and its parents) and the user config.
2. In the radin source repo, also run `cargo run -q -- context`. It adds each host render of radin's skills, with the ceilings in `src/context.rs`. Run `cargo run -q -- stats --no-repos --no-companions --since <date>` too. Read `radin context load` and `radin roles`. Use the date the user names, else omit `--since`. An empty `radin context load` means no transcripts matched: say so and skip it.

The table counts files only. A session also loads plugin skills, MCP server instructions, hook output, the output style and `MEMORY.md`, so the real load runs higher. Say so in the Reply.

Counts are an estimate of 4 bytes a token, and a `Read` adds line numbers to measured ones. Compare items with each other, never one table with another.

Done when every table printed has at least one row.

## Step 2: Rank

Each hit is a candidate. Record its number, not a verdict.

- **Heavy file.** The top three rows of `repo: auto-loaded`, and any single file over 2,000 tokens.
- **Same text twice.** Two loaded files that repeat a rule, or a project file that restates a user file.
- **Reference in the always-loaded set.** A file that one kind of task needs.
- **Near the ceiling.** In the radin repo, a total within 10% of `ALWAYS_CEILING` or `ROUTE_CEILING`.
- **Named by most routes.** A lib file that more than half the routes name.
- **Paid twice.** A lib file or skill whose `loads` exceeds its `sessions`.
- **Heavy render.** A `prompt <kind>` or `agent radin-<role> report` row above 1,000 tokens on average.
- **Costly role.** The `radin roles` rows with the highest `avg-tokens`.

Done when every row has passed through each test that applies.

## Step 3: Audit

Open each candidate in full. Name the model the files target: the model the user names, else the model running this audit. Apply every pattern and the cache hazards in `RADIN_LIB/radin-audit-patterns.md`. Run `git blame` on each emphatic or prohibitive line and ask which failure it prevented, and whether that failure still occurs.

Check each named path, command and flag against the repo by reading it. Run none of them.

Done when every candidate has either named lines to cut or a one-line reason it stays.

## Step 4: Report

Edit nothing. List the findings in the entry format of the patterns file, then the sums: always-loaded tokens, and tokens saved if every High and Medium finding lands. A surface with no hit gets "nothing to trim", with its totals.

For each entry the user keeps, run `/radin-record`. After a cut lands, run Step 1 again and compare. In the radin repo, set the ceiling in `src/context.rs` to the new total plus 8%. A prose edit that claims to change behavior follows "Measure a prose edit" in `CONTRIBUTING.md`.

**Reply:** the ranked findings, then the two totals that frame them: always-loaded tokens per scope (project, user) and the tokens saved.
