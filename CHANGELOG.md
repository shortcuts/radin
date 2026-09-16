# Changelog

Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## Unreleased

### Added

- `radin state plan-wave <namespace-dir>` — every `pending` task that still
  needs a `**Plan:**` pointer, lowest order first, as `plan<TAB><id>`, so the
  router dispatches the whole planning wave from one call and joins nothing
  itself. Exit 1 when every pending task is already planned.
- `radin backlog plan-target <id-or-title> [<sub-slug>]` — one call resolving a
  task for planning: `id`/`title`/`task_file`/`plan_file` lines plus one `plan`
  line per existing pointer, with the four outcomes as exit codes (0 resolved,
  1 no match, 2 several with candidates on stderr, 3 already planned). It also
  owns the `plans/<task-id>.md` path convention, including the
  `<task-id>-<sub-slug>.md` form a split plan uses.
- `radin scope` now resolves ranges (`last commit`, `last <n> commits`,
  `<rev>..<rev>`) as `type range`, prints a `passes` line naming the ponytail
  skill(s) that scope type calls for, and gained `--in-scope`, which classifies
  `path:line` citations on stdin as `in`/`out` against the resolved scope and
  ends with a `dropped` count.

### Fixed

- `radin cbm-config install` passes `SHELL=/bin/sh` to
  `codebase-memory-mcp install`. Upstream 0.11.0's last step writes its PATH
  line to the rc file of `$SHELL` and exits 1 with no message under fish or
  bash, so every install on those shells reported the companion as `PARTIAL`.
- `radin doctor`'s install-time-substitution check no longer flags itself.
  `radin-doctor.sh` ships into the lib directory it scans, so its own search
  pattern matched and every real install reported one invalid file.

### Changed

- `radin-execute` names its on-demand `lib/*.md` docs through a `RADIN_LIB`
  token that `install.sh` resolves to an absolute path. The Read tool takes no
  `$HOME`, so the previous literal path made the model expand it first.
- Every skill and the on-demand `lib/*.md` files drop their explanations of how
  radin's CLI works internally; each CLI call now carries at most one line
  saying what it does. `AGENTS.md` gains a `Writing prose for agents` section
  with the rules that keep them that way. No behaviour change.

- `install.sh` no longer relays `codebase-memory-mcp`'s per-item configuration
  trace or upstream's per-client inventory; both go to
  `~/.claude/.radin/cbm-config.log`, named only when the step did not come out
  clean. A first install now ends with what to run next.

- `radin-execute` plans in one wave: Phase 3.5 dispatches a planning sub-agent
  for every confirmed task that lacks a plan, all in one message, before the
  first execution sub-agent runs. Fact-finders for several blocked tasks
  likewise share one message. Re-run `install.sh` (or `radin update`) to pick
  the skill up.

- `radin-plan`, `radin-record` and `radin-review` no longer compute anything
  from CLI output. `radin-plan` opens on `plan-target` and routes on its exit
  code instead of counting `find` lines and following up with `meta`, and its
  report is the lines it already printed rather than a hand-built table.
  `radin-review` drops its `backlog count` baseline and subtraction, takes its
  ponytail passes from the `passes` line, and drops out-of-scope findings
  through `scope --in-scope` instead of eyeballing each citation against the
  diff. Its `fix`-versus-`refactor` split is stated once, as a rule.
  `radin-record`'s body template is four one-line imperatives, and the stub
  exemption to the grilling gate is stated once, at the gate. Re-run
  `install.sh` (or `radin update`) to pick the three skills up.

- `radin-execute`'s Step 4a no longer judges whether a task is "a single
  obvious change": a task with no plan always gets a planning sub-agent, which
  can size it with the codebase in front of it. Phase 2 routes the order and
  the task-selection answers once each, and a revision loop re-asks the order
  alone — the selection already given stands. The router's "no report yet"
  versus "report without a `STATUS:` line" split now keys off one observable,
  whether the dispatch handed back content. Crash recovery's accept-or-reject
  branch is measured against the entry's own `**Acceptance:**` criteria, and an
  entry stating none is always the user's look.
- The execution sub-agent prompt states its `STATUS:` contract first instead of
  ninth, and its capability rules once instead of five times.
- Every rule that was stated in more than one prose file now has exactly one
  owner, with a pointer where a second reader needs it. A verbatim sub-agent
  fence in `lib/radin-execute-prompts.md` is the one exception, because a
  fence cannot carry a pointer; `docs/architecture.md` §"One rule, one file"
  records the ownership rules a future audit checks against. The moves:
  sub-agent capability limits and "sub-agents never sub-delegate" to
  `radin-execute`'s Core Constraints (plus each fence); the worktree/branch
  answers being `state prepare`'s alone to act on, Phase 2's unconditional
  gate, and "don't set `run_in_background`" to Core Constraints; "never
  synthesise an acceptance criterion" to `radin-record` Step 5; "never
  hand-edit the backlog, never guess on a broad ask" to the installed
  `~/.claude/CLAUDE.md` block; the category list to `radin-record` Step 4; the
  `--rank-needed` gate and its exit codes to `radin-execute` Phase 1 step 4;
  and non-interactivity to the prompt that dispatches a skill rather than the
  skill itself.
- `lib/radin-prioritization.md` lost its "Parsing the backlog" and "State file
  schema" sections. `docs/domain-models.md` owns both formats and the state
  section had already gone stale (no `in_progress`, no `deferred`). The file is
  now `radin-execute`'s alone, read at Phase 1 step 4 and only when
  `backlog order --rank-needed` exits 0.
- Phase 0's "never hand-parse" is narrowed to "never parse state to decide what
  to do next", which is what the resume triage's read-only pass could already
  live under. That read is now named as the one exception instead of
  contradicting the absolute.
- Backlog deduplication has a named owner: the user, prompted by
  `backlog duplicates` in `radin-execute`'s final summary. No radin skill
  merges entries, because a false-positive merge silently drops work.
- The installed concurrency rule dropped its `run_in_background: false` clause,
  which contradicted Core Constraints' "fork mode removes the parameter
  outright, so don't set it". **Re-run `install.sh` (or `radin update`)** to
  pick up that change and the new `~/.claude/CLAUDE.md` bullet.
- `radin tui` gains `o`, which pages `backlog order --report` in `$PAGER`: the
  execution order including the dependency overrides the `Shift-P` priority
  sort hides. The other verbs `order`/`field`/`duplicates` added stay
  LLM-facing and get no key.
- The five near-pure wrapper skills (`radin-show`, `radin-doctor`,
  `radin-uninstall`, `radin-stats`, `radin-setup-hooks`) are now the command,
  its exit-code route, and nothing else. What each script checks, removes or
  prints is stated once, in the script. `radin-stats` stops probing for its
  five sources — an uninstalled one fails visibly, which is the skip — and
  carries the measured-vs-benchmark label on each source instead of a second
  table. `radin-setup-hooks` reads `radin doctor`'s wiring section instead of
  `manifest.json`, and its three-cause failure table is gone: the script prints
  its own cause.

### Fixed

- The TUI pads and truncates every row by display column instead of by byte, so
  a task body holding a wide CJK or emoji glyph, a multi-byte character past the
  cut, or a tab no longer spills the right detail pane over the task list on the
  left. The header and footer bars count the same way.
- `radin-setup-hooks` no longer blames `python3` for the fallback path. The gate
  is the compiled `radin-cbm-json` helper, i.e. a C compiler at install time;
  `python3` was never involved. `radin-doctor` also dropped the claim that a
  missing companion tool needs suppressing from the "re-run `install.sh`"
  message — companion reachability never affects the exit code — and now names
  `radin update`, not a `radin-update` skill that does not exist.
- `/radin-record` now writes a dependency to the backlog's `depends_on` field
  instead of only to the entry body. It logged dependencies as prose on the
  grounds that `radin-execute`'s prioritization read entry bodies for that
  signal, which stopped being true once prioritization moved to the index
  line's `depends_on`: every dependency it recorded was invisible to the
  ordering pass built to consume it. It now runs `radin backlog set-deps` once
  per dependent entry after the batch is added, and still names the reason in
  the body.

### Changed

- `radin backlog` now owns the execution order instead of the model. `order`
  is the sort, the topological dependency fix and the Phase 2 report in one
  verb (`--rank-needed` is the "does a ranking pass run at all" gate,
  `--steps` prints `radin state steps-init`'s stdin format so Phase 3 is a
  pipe); `field` renders one Execution-prompt placeholder per call, including
  the plan pointers, the acceptance block and the skill deny-list filter; and
  `duplicates` scans the index for the duplicate ids and titles a hand edit
  leaves. `lib/radin-prioritization.md` is down to what is genuinely
  semantic: how to rank the unset-priority group, and a now-bounded rule for
  inferring one dependency from two entry bodies. `radin backlog list` is
  unchanged, default order included, so the TUI's parser still holds.
- `radin state` now owns `radin-execute`'s execution loop instead of the model.
  New verbs replace prose that composed leaf calls by hand: `task-next` (pick,
  dependency gate, block-and-skip in one call), `task-fail` and
  `task-diagnosis` (the `FAILED` route, its notes and its one Debug pass),
  `dirty-recover` (stash-and-fail a sub-agent's dirty tree), `recover` and
  `recover-reject` (crash triage), and `report` (the finished end-of-session
  report text). `task-done` now rejects a commit hash that is not a commit
  reachable from the task's branch, so an unsupported `SUCCESS` can no longer
  record one. A task the user defers at the Phase 2 gate is persisted as a
  `deferred` entry rather than remembered in context, and the one Debug pass a
  failing task gets is enforced by a flag on its entry, so it survives a
  resume. `lib/radin-execute-dirty.md` is gone — it was one CLI call.

- `radin tui` now notices a backlog another shell changed: every 5 seconds an
  idle TUI checks `index.jsonl`'s mtime and size, and reloads only when they
  moved, so a task an agent added in another terminal appears at the bottom and
  a removed one disappears with no keypress. The reload keeps what you were
  looking at -- the selected task (by id, not row number), the collapsed epics,
  the scroll position and the active `Shift-` sort -- and an untouched index
  costs one `stat` per interval, no `backlog list` call and no repaint, so a
  footer message stays on screen.

- `radin tui` now lists tasks in creation order, so editing a task no longer
  makes its row jump: changing a category or a priority leaves the row where it
  was, and a new task appends at the bottom. `Shift-A`, `Shift-P`, `Shift-C`
  and `Shift-T` sort by creation order, priority, category and title when a
  reorder is what you want; the active one shows in the header
  (`sort:created`), and it lasts for the session only. `radin backlog list`
  gains `--order created|priority` and still defaults to `priority`, so nothing
  agent-facing changes.

- `radin tui`'s detail is now a right-hand pane instead of a strip across the
  bottom: the tree takes the left 40% of the width, the selected row's detail
  the right 60%, and the task body renders through a hand-rolled markdown
  subset (heading bold, `>` quote dim and indented, bullet re-marked `•`, `**`
  stripped). `ctrl-d`/`ctrl-u` scroll that pane half a pane at a time and never
  move the tree selection; `j`/`k` still only move the selection. Under 100
  columns no right pane is drawn and `enter` on a task row opens the same
  renderer full-screen, dismissed with `q`/ESC -- so `enter` no longer opens
  `$EDITOR`, `e` is the edit key. On a wider terminal `enter` on a task row
  does nothing, and on an epic header it still collapses. `e` on an epic header
  now opens that epic's `DESCRIPTION.md` in `$EDITOR` -- previously the only
  way to write it was at creation time, via `E`. `v` still opens the fully
  composed document in `$PAGER`.

- `radin tui` looks less bare: the two panes are separated by a `â` divider
  instead of a blank column, the detail opens with a
  `category Â· id Â· priority` line and a full-width rule before the body, an
  epic header row is cyan, the header and footer bars are reverse video, and the
  footer is one short line of keys that fits an 80-column terminal (`?` still
  lists every key). Colour stays structural outside the priority cell, so
  nothing new can be misread as a priority, and `NO_COLOR` drops all of it.
- Task priority is now the Fibonacci scale `1 2 3 5 8 13 21`, ascending with
  "higher wins" (so `21` is the most important, not the largest estimate).
  `radin backlog add --priority` and `set-priority` reject anything else, and
  `radin tui`'s `p` picks from the seven values plus a clear entry instead of
  reading typed text. Validation is write-only: priorities already stored
  off-scale keep loading, listing and rendering, and nothing rewrites them.
- `radin tui` now shows priority as its own column, left of the category, and
  colours only that cell from a fixed map: `21`/`13` red, `8`/`5` yellow,
  `3`/`2`/`1` green, nothing when unset or off the scale. The row itself is no
  longer coloured, and the band is no longer relative to the priorities on
  screen, so an unrelated task's number cannot change this one's colour.
  `NO_COLOR` still turns it off.
- `radin tui` draws an epic's tasks as a tree: `├──` for each child and `└──`
  for the last, instead of a two-space indent. Ungrouped tasks stay at the root
  with no connector, and a collapsed epic keeps its `+`/`-` marker.
- Bare `radin` on a terminal now opens the TUI instead of printing usage; off a
  terminal it still prints the usage text and exits non-zero. `radin help`
  prints it anywhere.
- `radin tui`: `/` is now a search, not a filter -- every row stays visible and
  matching rows are marked with a `*`. `n`/`N` jump to the next/previous match
  and wrap. Creating a task moved from `n` to `a`.
- Every JSON read and write radin does for itself is now C
  (`lib/radin-cbm-json.c`), built by `install.sh` with `cc`: the
  `settings.json`/`.claude.json` surgery behind `radin cbm-config`, and the
  `.mcp.json` merge behind `radin cbm-hooks mcp`. radin needs no `python3` of
  its own any more -- the remaining `python3` check in `install.sh` is for
  headroom-ai, a third-party pipx package. With no compiler `install.sh` falls
  back to `radin cbm-hooks claude-md`, and `radin cbm-hooks mcp` prints the
  `.mcp.json` entry to paste by hand instead of writing it.
- `radin tui` is now C (`lib/radin-tui.c`), built by `install.sh` with `cc` into
  `~/.claude/.radin/bin/radin-tui`. The build is advisory: with no compiler the
  rest of radin installs and `radin backlog show` covers the reading. Keys,
  screens and every mutation path are unchanged.
- `radin backlog` sources `radin-namespace.sh` instead of forking it, and the
  namespace `mkdir -p` only runs when a directory is missing: ~13ms off every
  CLI call the skills make.
- `radin-execute`'s four cold paths -- blocked-task routing, the first-run
  worktree/branch questions, the dirty-tree recovery, and resume plus the state
  persistence contract -- moved out of the skill body into `lib/` files read
  only when their trigger fires. The skill sits in the user's own context for
  the whole session and is ~80 lines shorter; behaviour is unchanged.

### Fixed

- `make bench` and its python driver are gone with the bash TUI they measured.
- The test suite runs in ~20s instead of ~6min: redundant tests removed, one
  compiled mock instead of a shell stub per command, recorded installs replayed,
  and `git`'s fsync off for the throwaway repos the tests build.

## [1.0.1](https://github.com/shortcuts/radin/compare/v1.0.0...v1.0.1) (2026-09-14)

### Bug Fixes

- install ([5769cca](https://github.com/shortcuts/radin/commit/5769ccab7f487983c07c3dfbd33201eed186b26f))
- tests ([77b8f3a](https://github.com/shortcuts/radin/commit/77b8f3a80748a17df4e65d347a7bfb27a3588322))

## 1.0.0 (2026-09-13)

### ⚠ BREAKING CHANGES

- **install:** install.sh no longer prompts per companion tool, for the ~/.local/bin/radin symlink, or for the ~/.claude/CLAUDE.md guidance block. --yes now only skips the three behaviour questions.
- **install:** codebase-memory-mcp replaces code-review-graph
- **install:** headroom installs on a single yes
- remove the radin-execute-background agent
- **radin-execute-background:** rename from -detached, trim the prose
- **radin-execute:** ship as skill, not agent

### Features

- add force mode for updates ([a4fd443](https://github.com/shortcuts/radin/commit/a4fd4434479903d0046e0209dc11f6eeada08f9b))
- add headroom as optional companion tool ([0d7d5cb](https://github.com/shortcuts/radin/commit/0d7d5cbf25174c715d751765f9424858119b633f))
- add i-have-adhd ([0e5e5a4](https://github.com/shortcuts/radin/commit/0e5e5a47cdfb48c229fd0b88fa2bf38a745da76d))
- add openai.yaml agent manifests to radin skills ([7c4047f](https://github.com/shortcuts/radin/commit/7c4047f435e12312e87752bd94732d5c1d6574ac))
- add ponytail ([1513547](https://github.com/shortcuts/radin/commit/1513547f9fea31f4186c438ffb8def102c8c366d))
- add radin-doctor install verification command ([74bb980](https://github.com/shortcuts/radin/commit/74bb980319940d2c2d362517c08d3482be47cd30))
- add radin-record skill ([656fe06](https://github.com/shortcuts/radin/commit/656fe06721949ba74e8a4cfc16fdb22d17dc1601))
- add radin-show skill to print current project's backlog ([9577a75](https://github.com/shortcuts/radin/commit/9577a75474ae0a8a586d3f3ac47eaba2fbb8c2fc))
- add radin-state.sh CLI, stop hand-editing execute's state JSON ([8404994](https://github.com/shortcuts/radin/commit/840499476ab6ebf78851abdc54c93641881d3fa6))
- add radin-stats skill ([3f4e1fd](https://github.com/shortcuts/radin/commit/3f4e1fd9c24491eb4eb1dbe72613b7c5a4170efd))
- add release-please automation ([532c601](https://github.com/shortcuts/radin/commit/532c601c11761178347ef8e5e53545f801d002ee))
- allow configuring model on agents ([729b1f7](https://github.com/shortcuts/radin/commit/729b1f7c7e9446fc8d5ca2848d0c81e45afa6793))
- **backlog:** env --export prints source-able export lines ([16f530b](https://github.com/shortcuts/radin/commit/16f530bfdb5f5d89dcc39b2c4810e374c260b5e8))
- better agent granularity ([bbd74e7](https://github.com/shortcuts/radin/commit/bbd74e72c9f4e9fc9ddaefb476af94b59290a1fc))
- **cli:** radin update refreshes the whole stack non-destructively ([97dd136](https://github.com/shortcuts/radin/commit/97dd1360ed3a68c54af6e22c0cd63f502f5f1c19))
- confirm order and worktree/branch via fixed choices ([8bd82d8](https://github.com/shortcuts/radin/commit/8bd82d88372179740892447c91f0002c6d0c9011))
- decide rtk leverage and add sub-agent guidance ([6f6b61c](https://github.com/shortcuts/radin/commit/6f6b61cbb5969d7d24fbe008344f165abcb47fe3))
- dependency-aware task ordering and drift detection in radin-execute ([3d298b2](https://github.com/shortcuts/radin/commit/3d298b217abf7f35bf862fbacc4acc9c531d123f))
- gate planning on ponytail, self-review plans before handoff ([543a899](https://github.com/shortcuts/radin/commit/543a899f4125149839eee208c6b6b94e64d07fe2))
- **install:** ask whether radin-execute may run sub-agents in parallel ([1cc2f57](https://github.com/shortcuts/radin/commit/1cc2f57371992309f7bf574d66ff4568f7e2c0ac))
- **install:** codebase-memory-mcp replaces code-review-graph ([0033cd2](https://github.com/shortcuts/radin/commit/0033cd28b9ad7c09fe71b2832bbac01e724df339))
- **install:** headroom installs on a single yes ([de116bf](https://github.com/shortcuts/radin/commit/de116bf3685a8a79a62330b13c2a7bdf734850de))
- **install:** install the whole stack, ask only about behaviour ([3392393](https://github.com/shortcuts/radin/commit/3392393ce76ed8023dfb5c8d28f5578ed6e4e612))
- **install:** one-pick shortcut for sub-agent models ([83dd65b](https://github.com/shortcuts/radin/commit/83dd65bc6e751beec04215b8e48636d2d9a947fe))
- **install:** opt-in radin guidance block in ~/.claude/CLAUDE.md ([e8b0b0c](https://github.com/shortcuts/radin/commit/e8b0b0cc4ba706c2550f56f0a694e03d0c8b6dde))
- **install:** RADIN_CLI token replaces hardcoded CLI invocations ([38b0062](https://github.com/shortcuts/radin/commit/38b0062a4f4c6c90fa1488ce53d392a293fae955))
- leverage code-review-graph in radin-plan and radin-execute ([aa1e2f4](https://github.com/shortcuts/radin/commit/aa1e2f4ecf50fbb674496caf1bafabdf1940d17e))
- **lib:** add radin-backlog.sh CLI for deterministic backlog operations ([477b5ef](https://github.com/shortcuts/radin/commit/477b5efed8e3103a50e07226aefc707b14892bcf))
- offload deterministic logic from agents/skills to CLIs ([bd57713](https://github.com/shortcuts/radin/commit/bd5771399a3302eebc9a059ed0c470ec6ae4bef7))
- radin CLI dispatcher, quiet companion installs ([3f60a9f](https://github.com/shortcuts/radin/commit/3f60a9f81193eb4c74704048b45c6c67f98df01b))
- radin stack ([debe84e](https://github.com/shortcuts/radin/commit/debe84e97a8edbe091d0c5148c8e2e0f7ba47e04))
- **radin-execute-detached:** opt-in agent for background backlog runs ([3cfcb6a](https://github.com/shortcuts/radin/commit/3cfcb6a9237c489a2686c38c80d2c4ef274828e2))
- **radin-execute:** interactive vs autonomous interaction modes ([cf0eee3](https://github.com/shortcuts/radin/commit/cf0eee315bf1a19eb1741a75428696124cea09d0))
- **radin-execute:** sync orchestration, blocked status, sub-agent planning ([7a8a338](https://github.com/shortcuts/radin/commit/7a8a338705b0ec9b383a0124affcd1d114113808))
- **radin-execute:** verify a SUCCESS, diagnose a FAILED ([7b0e739](https://github.com/shortcuts/radin/commit/7b0e73967cca4096d8fd5c6a4bfd9be29a6d5be4))
- **radin-plan:** delegate interview to /grilling, add /research for API facts ([23be4fb](https://github.com/shortcuts/radin/commit/23be4fbd97ed2bcb651d3e81ec6ba72ce6806487))
- **radin-record:** grill open decisions at record time ([c9cb7e4](https://github.com/shortcuts/radin/commit/c9cb7e423a1b2a4d43f8886b03ad4aac5fc11e92))
- remove the radin-execute-background agent ([a709abc](https://github.com/shortcuts/radin/commit/a709abc3e9e4ff5b95a7c2095da4af1e7a8cc8ee))
- simplify install helper ([b5b939b](https://github.com/shortcuts/radin/commit/b5b939b6232a3608e0cb8e152e39d363898e060d))
- split backlog storage into a JSONL index + one file per task ([192ef30](https://github.com/shortcuts/radin/commit/192ef3009f1556b4a8170270f52cae01b3667bdd))
- **state:** recover tasks a killed session left mid-flight ([60ba6c7](https://github.com/shortcuts/radin/commit/60ba6c781b769b4f60368148c0ba9bd8cf8f5059))
- **uninstall:** add radin-uninstall skill and lib script ([2ca05f2](https://github.com/shortcuts/radin/commit/2ca05f26300aad1481581f1f2adb85322ed2e53f))
- vendor mattpocock-skills as a companion tool ([56c1d9b](https://github.com/shortcuts/radin/commit/56c1d9b80d4d61fbc5b7c77159bc63bd781692e0))
- wire code-review-graph through radin's own merge-only script ([b4a8087](https://github.com/shortcuts/radin/commit/b4a8087103105d80bed26660481b73ee6dbdc5e7))
- write install manifest on every install.sh run ([11c3476](https://github.com/shortcuts/radin/commit/11c3476bfb84168514bacf961c7033aabd0a3f53))

### Bug Fixes

- **AGENTS.md:** expand companion-tool list to include all six tools ([dbc126d](https://github.com/shortcuts/radin/commit/dbc126d4ecee99413d024f30ee0fc829dea216d8))
- **AGENTS.md:** remove outdated repo-root BACKLOG.md section ([7001e00](https://github.com/shortcuts/radin/commit/7001e00479a2c81fd8b80611743c5aaebdccdc92))
- backlog path simplification ([76cb098](https://github.com/shortcuts/radin/commit/76cb098f36a54f9cb0eda37a73b1652b0339bc94))
- **BACKLOG:** improve find file logic ([d0070f6](https://github.com/shortcuts/radin/commit/d0070f6123c702ca33520513bb1a5934ace08b32))
- better leverage grilling sessions ([65bc7e4](https://github.com/shortcuts/radin/commit/65bc7e46e3bbd791579ec6755965e0aa5a807940))
- **cbm-config:** accept an install that wired Claude Code then failed later ([3ac8355](https://github.com/shortcuts/radin/commit/3ac8355521c1dcd031b64e6a8aee64cf8ccada3e))
- **cbm-config:** reinstall fixes a hook path from another machine ([1d0272e](https://github.com/shortcuts/radin/commit/1d0272eb40b4b99c2444f186b4c0493a76a3a6f4))
- **cbm-config:** stop restoring upstream's own hook entries ([dd10248](https://github.com/shortcuts/radin/commit/dd102480f4a4dc8494098ac4a0ae90872373b45e))
- **cbm-config:** survive a symlinked ~/.claude and an upstream no-op ([94a5dc5](https://github.com/shortcuts/radin/commit/94a5dc531cd11715822bd29b8ddb7913f2862a0b))
- check namespaced ISSUES_FILE before repo-root fallback ([c1c144f](https://github.com/shortcuts/radin/commit/c1c144ff91cfd6c354f1f3f8019e151816c1b65c))
- CLAUDE.md ([3c5da6f](https://github.com/shortcuts/radin/commit/3c5da6f072fb3965c14f567bbf2f8518127646ef))
- commit orchestrator rename ([0f8f0af](https://github.com/shortcuts/radin/commit/0f8f0afe4f9862ad685ed1ee52521ab846129869))
- correct two wrong claims about sub-agent tool pools ([0ccbb50](https://github.com/shortcuts/radin/commit/0ccbb5047fa5b8ef32c42017e3accff3edf5e146))
- curl | bash install silently dies on read prompts ([f7b037c](https://github.com/shortcuts/radin/commit/f7b037cb7b7c76dd883df672383ecc51bd8c7baa))
- do not execute sub skill right away ([94244a4](https://github.com/shortcuts/radin/commit/94244a4ad1caff9b1728476990c236555671c2dd))
- dynamic workflows ([a22a8e9](https://github.com/shortcuts/radin/commit/a22a8e97891ab82fea86520b711e5037498d91e7))
- execute should ask for a confirmation ([ac797c0](https://github.com/shortcuts/radin/commit/ac797c01aba720fce4b7611e6c782df224f3d646))
- **execute:** force hard stop ([685ee1e](https://github.com/shortcuts/radin/commit/685ee1e7cf3a2b54b8568d01b30615f98f16506f))
- headroom ([c9ee0d5](https://github.com/shortcuts/radin/commit/c9ee0d5ac1782883e5f948912b25c50762af9f73))
- install ([dd5bf4b](https://github.com/shortcuts/radin/commit/dd5bf4b18e022ce45d4fefe0ba75b862cc17d3cd))
- install requirements on python ([49ec94b](https://github.com/shortcuts/radin/commit/49ec94b73ffacda3d06d406ad9a1c734f99484e8))
- **install:** stop growing CLAUDE.md by a newline each run ([ced0a70](https://github.com/shortcuts/radin/commit/ced0a70e46057c6ab879e3839ccbf209e92c2dd2))
- interactive plan ([daf12fa](https://github.com/shortcuts/radin/commit/daf12fa3cdaa927171c6aa693fb3470a944e5185))
- invoke sub skill ([1abef43](https://github.com/shortcuts/radin/commit/1abef43490bf066adb58cbf6a25e06d3c752c2a3))
- keep skill when recorded ([f0e1a5d](https://github.com/shortcuts/radin/commit/f0e1a5d2876e31e34e7b02e82a04b307bcff8ae6))
- less assumptions ([717d6fe](https://github.com/shortcuts/radin/commit/717d6fea075116c75ac861878b5ed8f1fc94ed1e))
- lib location ([731cb9a](https://github.com/shortcuts/radin/commit/731cb9abab88019f413c730e2550a1d0b926fe45))
- lint ([f045cfd](https://github.com/shortcuts/radin/commit/f045cfdba064aa62307457cd4fe628bc1bafed14))
- lint ([fb28845](https://github.com/shortcuts/radin/commit/fb28845c48be9c641fae5d72c758f5e73fd09e87))
- orchestrator must not leave dirty working tree ([266ef6d](https://github.com/shortcuts/radin/commit/266ef6de5d337c115a28a6398e93e0cc4f56fbda))
- orphaned backlog items ([51ab430](https://github.com/shortcuts/radin/commit/51ab430e67f8979fc54e74ad81000bdb1d235e65))
- **plan:** add record autonomously ([1821b8c](https://github.com/shortcuts/radin/commit/1821b8c116a4c262f6c76d62d2f6f85ec58369d0))
- **prompts:** reconcile every sub-agent claim with the verified tool pool ([d573bf4](https://github.com/shortcuts/radin/commit/d573bf4211f9e7d7604d48ce0e4570ae62091b94))
- properly track worktree/branch ([2143342](https://github.com/shortcuts/radin/commit/21433425dd53318216cf2ca2231f42bfece9328f))
- **radin-execute:** add fallback for caveman-commit when plugin absent ([b01a5f3](https://github.com/shortcuts/radin/commit/b01a5f3eb9d8084fa50bb4b9f4ce487e26df289f))
- **radin-execute:** close non-interactive gaps in loop, planning, review ([d5edf54](https://github.com/shortcuts/radin/commit/d5edf54e2cf45ec6c4ac1c052ceaa8166a7f903e))
- **radin-execute:** correct Phase 4/5 references and typo ([3c514a9](https://github.com/shortcuts/radin/commit/3c514a98fb7fb9e4a0d34f952f792b3c2da5a51b))
- **radin-execute:** forbid inventing work when backlog missing or exhausted ([678da0f](https://github.com/shortcuts/radin/commit/678da0f1eee9f7eee05e3820e97a009339cf0953))
- **radin-execute:** keep radin namespace out of tree checks, close ask-path gaps ([6c985b8](https://github.com/shortcuts/radin/commit/6c985b8405efe8116563aaf3c3cca14f74498e78))
- **radin-execute:** remove completed entries from BACKLOG.md immediately ([7a6e4d7](https://github.com/shortcuts/radin/commit/7a6e4d7a85b0107514ab7e7632e2096b2cb7b06e))
- **radin-execute:** stash dirty trees instead of stranding them, report failures with recovery steps ([ab17ab0](https://github.com/shortcuts/radin/commit/ab17ab0d91051a7bf7d0a5f028af52c905bdfbb6))
- **radin-execute:** stop hanging on skills a sub-agent can't run ([cefe5c3](https://github.com/shortcuts/radin/commit/cefe5c34bbe4300493700732246cfaab60cfc27f))
- **radin-execute:** verify backlog existence mechanically, not by inference ([80f90a4](https://github.com/shortcuts/radin/commit/80f90a48722f285fe753e8599f9c889aaeec5943))
- **radin-record,radin-execute:** grill decisions at record time, checkpoint huge backlogs ([379901d](https://github.com/shortcuts/radin/commit/379901de915464cec9dba3d684211b7bbc658c4a))
- **radin-record:** quote the raising text verbatim in the entry body ([b81d5eb](https://github.com/shortcuts/radin/commit/b81d5eb9b2fb65292e0cb9bf801dc4151e9c3954))
- **radin-review:** confine findings to the resolved scope ([624158e](https://github.com/shortcuts/radin/commit/624158e3902de7588225622e5482ab9717a7a114))
- **README:** correct radin-execute leverage table to show /radin-review ([c551636](https://github.com/shortcuts/radin/commit/c551636a4592f228ee4b6b1ed07c1d7945a3e953))
- redundant ISSUES.md file ([e07a7af](https://github.com/shortcuts/radin/commit/e07a7afa0c1891c986530208bf455043fb733562))
- remove orphan items from the backlog ([72027f5](https://github.com/shortcuts/radin/commit/72027f5636b390a17b420a05988649d7722043bc))
- review ([5742c4d](https://github.com/shortcuts/radin/commit/5742c4d407cb16f2977f4b633989c8352c7caf94))
- review pick process ([cf5c534](https://github.com/shortcuts/radin/commit/cf5c534ce5e5cebbb48bf4733909a66066a93916))
- review with grilling ([a950932](https://github.com/shortcuts/radin/commit/a950932558a6da4eb7d120f7dc6582662fc0d4dc))
- scripts ([df57a9c](https://github.com/shortcuts/radin/commit/df57a9cafcd90f40c9d81e6851cad9a583c95929))
- silent install mode ([948644f](https://github.com/shortcuts/radin/commit/948644ff898e6368b93e6ec4fcc26e0673033d50))
- stats skill ([c8d037b](https://github.com/shortcuts/radin/commit/c8d037bdbf2c778a3f3d22144b6ad29f6f39c528))
- stop biasing orchestrator/plan agents toward repo-root ISSUES.md ([582cbbc](https://github.com/shortcuts/radin/commit/582cbbcbe76ac31e0147a882fcddf929e9a404d1))
- strict execute instructions ([02b9fce](https://github.com/shortcuts/radin/commit/02b9fce2fdfaba286134e3c3ae4eba4a499cb456))
- tests ([a803bb6](https://github.com/shortcuts/radin/commit/a803bb6abaadcb6b2ca9d05f0cc27947159f52f2))
- tests without homebrew ([95bd9b3](https://github.com/shortcuts/radin/commit/95bd9b330c1932cfc7133f8d0bf1533a22e8c7c7))
- **thermo-nuclear:** allow model invoke ([78d7779](https://github.com/shortcuts/radin/commit/78d777958abe5afa21528c4b07e2717e88df8b16))
- update path ([18e3c59](https://github.com/shortcuts/radin/commit/18e3c59c537901d681898ae31013da3e31356f8d))

### Code Refactoring

- **radin-execute-background:** rename from -detached, trim the prose ([634b1f1](https://github.com/shortcuts/radin/commit/634b1f18c2b1babcde2eed00efc877e3486f3e41))
- **radin-execute:** ship as skill, not agent ([020204e](https://github.com/shortcuts/radin/commit/020204ebf658bf4eaa1bc8904895db7989391ae9))

## [Unreleased]

### Added

- `radin update`: one command updates the whole stack — radin's own skills and
  lib scripts plus every companion tool. It pulls a dev clone (only when clean
  and fast-forwardable) or downloads the newest release, then re-runs
  `install.sh --update`. That mode implies `--force` and `--yes` and reads the
  previous `manifest.json`, so concurrency, refuter pass and sub-agent models
  keep their recorded answers instead of being re-asked or reset. Nothing is
  deleted: files are copied over, companion tools take their own upgrade path,
  and upstream's destructive `codebase-memory-mcp` config write stays
  bracketed. `install.sh` now records `install_root` and one
  `model_<role>` key per sub-agent role in the manifest.

- `radin-execute` can verify each task before it records it. `install.sh` asks
  (default no); when it is on, a refuter sub-agent gets the commit diff, the
  task file, and the plan — never the execution sub-agent's own report — and
  reruns the repo's checks itself. It answers `ACCEPT`, `REWORK` with
  must-fixes (appended to the task file, task re-dispatched), or `UNVERIFIED`,
  which is recorded and flagged in the final summary. Structure and taste
  findings go to a `/radin-review` pass it invokes, which logs backlog entries
  and blocks nothing.
- A `STATUS: FAILED` task now gets one read-only diagnosis before it is
  parked. The debug sub-agent reproduces the failure, reports the root cause,
  and the router appends it to the task file and retries once. A retry with no
  new information used to just fail the same way and burn an attempt.
- Long evidence from a fact-finding or debug sub-agent goes to
  `.claude/.radin/state/facts/<task-id>.md`, with a `**Facts:**` pointer on
  the task file. Everything stays scoped to the one task that needed it —
  there is deliberately no shared cross-task notes file.
- `radin-review` ends with one question: leave the logged findings in the
  backlog, or run `/radin-execute` right away. The entries are written either
  way; the question only decides whether the run starts now.

### Fixed

- **A `~/.claude` shared between machines no longer keeps the other machine's
  paths.** Upstream bakes an absolute `$HOME` into every hook script and
  `mcpServers` command it writes, and leaves an existing file or entry alone on
  a rerun, so reinstalling on the second machine fixed nothing: hook scripts
  kept the first machine's `BIN=` (the hook ran and did nothing) and
  `settings.json` kept a hook path that does not exist (`no such file or
  directory` at every session start). `radin cbm-config install` now moves
  `<config-dir>/hooks/cbm-*` into `~/.claude/.radin/backups/hooks.<stamp>/`
  before upstream's install, so it writes them again for this machine;
  replaces an `mcpServers` command whose path does not exist; and prunes any
  hook entry whose command is a path that does not exist. A bare shim name is
  left alone — it resolves against Claude Code's `PATH`.
- **A stale `codebase-memory-mcp` hook no longer survives forever.** The
  restore put back every snapshot hook entry the file now lacked, including
  upstream's own. Upstream changes that command spelling between versions (a
  new resolved config dir, a renamed shim), which reads as "dropped" rather
  than replaced, so each version a machine had seen left one dead
  `SessionStart:startup` hook — `no such file or directory` on every session
  start. The restore now skips entries whose command names
  `codebase-memory-mcp` or a `cbm-*` shim; another tool's hooks are still put
  back. A rerun of `radin cbm-config install` clears the leftovers.
- **`codebase-memory-mcp` now installs on a machine whose `~/.claude` is a
  symlink.** Upstream refuses every write under a symlinked config directory
  and drops Claude Code from its target list while still exiting 0
  ([#1722](https://github.com/DeusData/codebase-memory-mcp/issues/1722)), so
  the install left no skill, no graph agents, no hooks and no MCP entry — and
  said it was wired. `radin cbm-config install` resolves the link and passes
  it as `CLAUDE_CONFIG_DIR`, then adopts the MCP entry that override stages in
  `<real-dir>/.claude.json` into `~/.claude.json`, the file Claude Code reads.
- **An upstream exit 0 that configured nothing now fails.** `radin cbm-config
  install` ends non-zero when neither a `cbm-*` hook nor the MCP entry is
  present afterwards, so `install.sh` falls back to its merge-only wiring
  instead of printing that the graph is ready.

### Changed

- **The stack is opinionated: `install.sh` no longer asks about any tool.**
  Every companion tool, the `~/.local/bin/radin` symlink, and the
  marker-scoped `~/.claude/CLAUDE.md` guidance block install unconditionally.
  Three questions remain, all about how `radin-execute` behaves: concurrency,
  refuter pass, sub-agent models. radin's skills delegate to these tools
  instead of reimplementing them, and a half-installed stack is the one case
  that delegation cannot rely on. A tool whose own installer fails is still
  advisory: it warns and the install continues.
- **Every skill now reaches for a shipped tool where it used to improvise.**
  Execution implements through the skill matching the task's category
  (`/caveman:surgical-patch` for a `fix`, `/caveman:safe-refactor` for a
  `refactor`, `/caveman:lean-build` for a `feat`); the debug sub-agent follows
  `/mattpocock-skills:diagnosing-bugs`; `radin-plan` sends module-boundary
  questions to `/mattpocock-skills:codebase-design`; `radin-review` harvests
  the `ponytail:` ledger with `/ponytail:ponytail-debt` on a directory scope;
  `radin-stats` reads `headroom savings`; and every prompt that runs a command
  or a diff names `rtk` and `headroom`'s structural tools. `AGENTS.md` records
  the one owner per job, so a delegation lands in one file and not two.
- **`codebase-memory-mcp` replaces `code-review-graph` as radin's code graph.**
  One static binary instead of a `pipx`/`pip3` install, 158 tree-sitter
  grammars, sub-millisecond queries, and a background watcher that keeps the
  graph current. `install.sh` installs the binary with `--skip-config`, sets
  `auto_index true`, then runs the whole tool's own Claude Code configuration:
  its skill, three graph agents, the user-scope MCP entry, and the
  `SessionStart`/`SubagentStart`/`PreToolUse` hooks that route Grep/Glob to the
  graph. No per-project step afterwards.
  `radin cbm-config install` (new, `lib/radin-cbm-config.sh`) brackets that
  write. Upstream
  [#1200](https://github.com/DeusData/codebase-memory-mcp/issues/1200) replaces
  the whole `SessionStart` array in `~/.claude/settings.json` instead of
  merging — open and unfixed through v0.10.8, and on a radin machine that array
  holds caveman's and ponytail's hooks. So radin snapshots `settings.json` and
  `~/.claude.json` into `~/.claude/.radin/backups/`, runs their installer, then
  restores every hook entry, top-level key and `mcpServers` entry the write
  dropped — pre-existing entries first, upstream's after, deep-equal entries
  never duplicated, one `RESTORED`/`INTACT` line each. A failed upstream
  install restores too. `radin cbm-config repair` runs the restore alone, for
  after `codebase-memory-mcp update` reruns the same write. `python3` is
  required for this path; without it `install.sh` installs the binary, skips
  upstream's configuration, and falls back to the merge-only wiring. The
  manifest records which path ran as `cbm_agent_config`.
  `lib/radin-crg-hooks.sh` becomes `lib/radin-cbm-hooks.sh`, and
  `radin crg-hooks` becomes `radin cbm-hooks`. It does two merge-only writes,
  down from three: the CLAUDE.md section and the repo's `.mcp.json` entry. The
  `settings.json` hook pair is gone with the watcher doing that job, so
  `radin cbm-hooks settings` no longer exists.
  `radin-plan`, `radin-review` and the execution, refuter and debug sub-agent
  prompts now name upstream's own tools (`search_graph`, `trace_path`,
  `detect_changes`, `get_code_snippet`, `query_graph`, `get_architecture`),
  and each says a graph hit is a pointer: read the file before editing, and
  never conclude absence from an empty result.
  Upgrading: re-run `install.sh`, then restart Claude Code so the MCP server
  loads. `/radin-setup-hooks` is only for the no-`python3` fallback now. `install.sh`
  only adds files, so a stale `~/.claude/.radin/lib/radin-crg-hooks.sh` stays
  until `/radin-uninstall` clears it (it now removes both names). Removing
  `code-review-graph` itself is your call: `pipx uninstall code-review-graph`,
  plus its own `~/.claude/settings.json` hooks and `.mcp.json` entries.
- `install.sh --yes` now takes every companion-tool question as yes, plus the
  `~/.claude/CLAUDE.md` guidance block, so one non-interactive command
  reproduces the same stack on another machine. Behaviour questions
  (concurrency, refuter pass, sub-agent models) keep their documented defaults.
- Plugin installs (caveman, ponytail, mattpocock-skills) are skipped with one
  line when the `claude` CLI is not on PATH, instead of being offered and then
  failing. They install through that CLI and nothing else.
- The codebase-memory-mcp bracket's limits are documented rather than implied:
  README gains "Caveats worth knowing" (what to run after an upstream
  `update`, why `repair` is not an undo, which configs are not covered, that
  snapshots hold your real settings, that a `.mcp.json` entry is
  machine-specific), and `docs/technical-constraints.md` gains the same list
  written for agents.
- Read-only sub-agent dispatches (planning, refuting, debugging,
  fact-finding) always run in parallel. The install-time concurrency answer
  now governs execution sub-agents only — the ones that write code and could
  collide.
- `install.sh` now asks for a model per sub-agent role — planning, execution,
  review, refuting, debugging, fact-finding, and the background agent —
  instead of one model for all of them. No radin file names a model any more; each role carries a
  token the installer fills in.
- The fact-finding sub-agent defaults to `haiku` instead of `sonnet`. Its
  prompt already requires the answer to cite the file path, command output, or
  version that establishes it, so the router can reject a wrong answer without
  spending a frontier model on retrieval. Every other role still defaults to
  `sonnet`.
- `radin-review` no longer logs findings on its own. It prints the in-scope
  findings, then gates on the user: log the ones it recommends, log all, or
  let the user pick by number. It then offers a per-finding refinement pass
  that sends each kept finding through `/mattpocock-skills:grilling`, one at a
  time, so a wrong scope, remedy, or priority gets corrected before the entry
  is written instead of after.
  A non-interactive caller (radin-execute's reviewer sub-agent has no
  `AskUserQuestion`) keeps the old log-everything behavior and says so in its
  report.

- `radin-execute` is a skill (`skills/radin-execute/SKILL.md`), not an agent.
  It ran as a sub-agent, and Claude Code removes `AskUserQuestion` from every
  sub-agent — so its Phase 2 gate could never actually ask, and every run fell
  back to ending its turn with the question and waiting to be re-invoked. As a
  skill it runs in your own conversation: it asks you directly, you can
  interrupt it, and the layer between your prompt and the router is gone. Its
  sub-agents are unchanged, one layer down, doing the work whose context is
  worth isolating.
- `radin-execute` dropped its 10-minute checkpoint. It existed because a
  sub-agent turn could not be interrupted; a skill's can, and every task's
  state is already durable when it lands.
- Corrected two claims radin had wrong about sub-agents. They **do** keep the
  `Agent` tool in the background — the second tool filter carves it out, and
  its absence from that filter's list is not removal — so nothing about
  delegation changes when a radin router runs as one. And nobody picks
  foreground or background: fork mode, on by default in interactive
  sessions, removes `run_in_background` from the `Agent` tool, so
  `radin-execute` and the shared sub-agent prompts no longer tell anyone to
  set it. A dispatched sub-agent's result may now arrive in a later turn, and
  the loop waits for it instead of reporting early.
- `install.sh` asks for one model instead of two. `radin-execute`'s own model
  is whatever you picked with `/model`, so only its sub-agents' model is a
  question — and the answer now reaches `lib/radin-execute-prompts.md` too,
  which previously stayed on `sonnet` whatever you chose.

### Fixed

- `radin cbm-config install` now works when `~/.claude` is a symlink. Upstream
  refuses every write under a symlinked config dir and then drops Claude Code
  from its target list while still exiting 0
  ([#1722](https://github.com/DeusData/codebase-memory-mcp/issues/1722), closed
  unresolved), which left a machine with no skill, no graph agents and no
  hooks. radin passes the resolved path as `CLAUDE_CONFIG_DIR`, adopts the
  `mcpServers` entry upstream then stages next to it into `~/.claude.json`
  where Claude Code reads it, and fails loudly when upstream exits 0 having
  configured nothing, so `install.sh` falls back to the merge-only wiring
  instead of claiming the tool is ready.

### Added

- `radin-execute-background`, opt-in at install time (`install.sh` asks,
  default no): the same backlog run in its own agent thread you visit
  yourself, so your own thread stays free. It invokes `/radin-execute` and
  follows every phase as written, sub-agent dispatch included. The one
  difference is that it asks you things in prose rather than with a picker,
  since a sub-agent has no `AskUserQuestion`. Default is no because
  `claude agents` reaches the same goal with nothing installed — a background
  session there is a full conversation, and `/radin-execute` runs unchanged
  in one.
- `lib/radin-execute-recovery.md` and `lib/radin-execute-reporting.md`:
  `radin-execute`'s crash-recovery routing and final-report template, read
  from disk when a run actually needs them. Recovery loads only when
  `radin-state.sh stuck` finds something, so most runs never pay for it.

### Removed

- `agents/radin-execute.md` — it's `skills/radin-execute/SKILL.md` now.
  `install.sh` reports a pre-migration copy at
  `~/.claude/agents/radin-execute.md` and prints the `rm` to run (it never
  deletes anything itself); `/radin-uninstall` removes it for you.

- `install.sh` no longer offers `i-have-adhd` as an optional companion
  tool. Dropped from the manifest, `radin-doctor`, and `radin-uninstall`
  advisories. Already-installed plugins stay untouched — remove them
  yourself with `claude plugin uninstall i-have-adhd@i-have-adhd`.

### Fixed

- Every companion-tool skill is now named with its plugin prefix in
  `radin-execute`, `radin-plan`, `radin-record`, `radin-review`,
  `radin-stats`, and the shared sub-agent prompts:
  `/mattpocock-skills:grilling`, `/ponytail:ponytail-review`,
  `/caveman:caveman-commit`, and so on. A bare `/grilling` also reads as an
  agent name, and radin's prompts got answered by a spawned agent, which
  cannot ask the user anything.

- The sub-agent prompt no longer lists `/mattpocock-skills:grilling` among
  skills that spawn an agent or a background task. It spawns neither. The
  prompt now skips it for its real reason: it asks the user in prose, and a
  sub-agent has no channel to the user.

- `radin-execute` can no longer skip its Phase 2 gate. Every run now asks
  the execution order and which tasks to tackle now, and an invoking prompt
  claiming the order is already approved is treated as context, not consent.
  Resumed runs reprint the list and re-ask both questions.

- `radin-execute` Phase 0 no longer stops on an empty backlog, which made
  Phase 1's "create an empty backlog or stop" branch unreachable. Phase 1
  step 1 owns that question.

- `radin-execute` gives `radin-state.sh set-status` a copy-pasteable
  signature. Six call sites referenced it in prose only, leaving the agent
  to invent the state-file path and the `note` quoting.

- `radin-execute` settles Phase 6 before printing Phase 5's summary. Phase 6
  told the agent to append a line to a report Phase 5 had already sent.

- `radin-execute` Phase 0.5 now states that `worktree: yes` always creates a
  `radin/<task-id>` branch, so the `branch` answer applies only under
  `worktree: no`, and tells the agent to say so when it asks. `prepare`
  always behaved this way.

- `install.sh` no longer runs `brew shellenv`. It prepended brew's bin to
  `PATH`, so the pyexpat preflight probed brew's python3 instead of the
  version-manager one (mise/pyenv) that pip/pipx would actually use, and
  refused to install code-review-graph/headroom on a healthy machine.

- A companion tool that fails to install (e.g. a broken Homebrew python
  bottle failing the pyexpat preflight) now warns and lets `install.sh`
  finish. `set -e` used to abort radin's own install at that point.

### Changed

- Every skill and agent prompt is rewritten in plain prose. Five short
  skills (`radin-show`, `radin-doctor`, `radin-uninstall`, `radin-stats`,
  `radin-setup-hooks`) shipped article-dropped text that read as a statement
  where an instruction was meant. Numbered steps in `radin-execute` Phase 1
  and Phase 5, and `radin-plan`'s `Step 4.5`, are renumbered to plain
  sequences.

- `install.sh --force` now updates companion tools that are already
  installed instead of re-running a no-op install: plugins go through
  `claude plugin update`, brew/pipx/pip installs run as upgrades. Without
  `--force`, an installed tool is still skipped (message says so).

- `install.sh` asks every question through an arrow-key picker instead of a
  free-text `[y/N]` answer, so a typo can no longer be read as a silent "no".
  Arrows (or `j`/`k`, or a digit) move, enter confirms, Ctrl-C aborts. Model
  prompts list `fable`/`opus`/`sonnet`/`haiku` instead of taking a hand-typed
  model name. Anything that isn't an interactive terminal -- piped answers,
  CI -- falls back to a numbered prompt, and an unreadable answer takes the
  default.

### Added

- `radin-state.sh prepare <namespace-dir> <id>` creates or reuses a task's
  worktree and branch from the answers in `session.json` and prints the one
  directory to work in. The execution sub-agent runs it instead of reading
  `WORKTREE_MODE`/`BRANCH_MODE` and issuing `git worktree add` /
  `git checkout -b` itself, so a recorded `no` can no longer be reinterpreted.

### Fixed

- `radin-execute` and its sub-agents now treat the session's answers —
  execution order, `WORKTREE_MODE`, `BRANCH_MODE`, concurrency — as
  binding. Phase 5's summary template hard-coded a per-task branch, and
  Phase 4's title said "Sequential" whatever the install chose, so a `no`
  answer read as a suggestion.
- `install.sh` fails loudly when the concurrency marker survives its
  substitution, instead of shipping an agent with no rule at all.
- `radin-plan` no longer sends a non-interactive run into `/research`, and
  `radin-record` no longer claims `radin-execute` resolves facts through
  it. Both hang a sub-agent, which cannot be notified when a background
  task finishes.

### Added

- `install.sh` asks whether `radin-execute` may run sub-agents in
  parallel (default no). The agent file itself states no concurrency rule —
  install's awk substitutes one at a marker line. Manifest records the
  answer as `parallel_execution`.

### Changed

- `radin-execute` own state files, `BACKLOG_STEPS.json` and
  `completed.json`, moved bracketed JSON array to JSONL (one compact
  object per line) — same convention backlog index already uses.
  All mutations now go thru new `lib/radin-state.sh` CLI
  (`set-status`/`remove`/`completed-add`/`completed-get`/`dirty-check`)
  instead of agent hand-editing JSON from prose instructions.
- **Breaking:** backlog no longer one monolithic `BACKLOG.md`. Now
  `.claude/.radin/backlog/index.jsonl` (one JSON object per task) plus
  one markdown file per task under `.claude/.radin/backlog/tasks/`. Removes
  line-number tracking from `radin-execute`/`radin-plan` entirely —
  task's file path (`tasks/<id>.md`) never goes stale, since inserting
  `**Plan:**` line into one task's file can't affect any other task's.
  Existing repos with old-style `BACKLOG.md` not auto-migrated:
  finish or manually split before upgrading. Run
  `/radin-show` to read backlog as before — renders same
  markdown view from new storage.

### Added

- `install.sh` now runs `python3`/`pyexpat` preflight before pipx/pip
  companion installs (code-review-graph, headroom). Broken Homebrew
  `python@3.14` bottle previously failed with opaque `libexpat` symbol
  traceback. Preflight prints fix (`brew reinstall
  --build-from-source python@3.14`) and skips step instead. README's
  new "Requirements" table lists every tool's prereqs and same
  Homebrew Python note.
- `install.sh` offers `headroom` as optional companion tool, alongside
  rtk/code-review-graph/caveman/i-have-adhd/ponytail. Python/pip
  footprint gets extra confirmation step beyond normal install
  prompt. Complements rtk (whole-session wrap vs. rtk's per-command
  compression) — not replacement, never installed or recommended by
  default.
- `install.sh` now writes `~/.claude/.radin/manifest.json` on every run: a
  generated snapshot of agent/skill/lib files it installed and which
  companion tools reachable, so other tooling has one file to read
  instead of reconstructing it from `install.sh`'s prose/cp lines.

### Changed

- `install.sh` installs shared `lib/` scripts (`radin-backlog.sh`,
  `radin-namespace.sh`, `radin-prioritization.md`) to `~/.claude/.radin/lib/`
  instead of `~/.claude/radin-lib/`. Every agent/skill reference updated to
  match.
- `install.sh` agent-model prompt matched `radin-execute.md`'s stale
  top-level default (`haiku`); frontmatter already moved to `sonnet`,
  so prompt's stated default and its `sed` replacement pattern both
  silently no-op'd. Both now match file's actual `sonnet` default.

- `radin-execute` now runs whole backlog in one turn. Delegates every
  task sub-agent synchronously (`run_in_background: false`) and waits for
  result — no longer spawns background sub-agent and ends its turn,
  which left nobody listening for completion.
- `radin-execute` never decides on user's behalf. Task needing judgment
  call the entry or plan doesn't settle gets marked `blocked` (new
  state-JSON status, next to `pending`/`failed`) with question, options,
  and recommendation — nothing implemented for it, rest of
  backlog still runs, final summary asks user to decide. Execution
  sub-agent got matching `STATUS: BLOCKED` report line.
- `radin-execute` keeps own context lean over long sessions: execution
  sub-agents told to report few lines plus `STATUS:` line, and
  state-persistence contract spells out recovery from disk after context
  compaction. Planning runs in own sub-agent so codebase exploration
  never lands in orchestrator's context — plan file on disk is
  handoff to execution sub-agent. Planning run non-interactive:
  where `/radin-plan` would ask user (split, overwrite) it takes
  non-destructive path, real ambiguity marks task `blocked` instead
  of guessing.
- `radin-execute` re-locates each entry by its `### title` at start of
  every task and refreshes `line_start`/`line_end` in state file —
  earlier `**Plan:**` insertions shift line numbers, stale spans meant
  reading wrong entry text.
- `/radin-plan` invoked non-interactively no longer guesses on entry
  matching: several candidate matches, or no match at all (backlog drift),
  stop planning run and mark task `blocked` instead of picking one
  or creating duplicate entry.
- `radin-execute`'s post-session review no longer asks for consent mid-run
  (as sub-agent, nobody can answer it). Review runs only when
  invoking prompt asked for one up front; otherwise final summary ends
  with `/radin-review` command user can run themselves.
- `radin-execute` got two interaction modes. Interactive (default)
  assumes user at keyboard: first open question stops run — state flushed to disk, question + options + recommendation and
  progress so far in report, re-invoking resumes from state file.
  Autonomous (say "autonomously" when invoking) parks blocked tasks, keeps
  executing rest, batches every question into final summary.
  Either way, answer given on re-invocation appended to entry's
  description in `BACKLOG.md` so planning/execution sub-agents read it.
- `radin-plan` now front-loads clarification as interview: invoked
  interactively walks entry's decision tree one question at a time,
  each with recommended answer, looks up facts in repo instead of
  asking them, doesn't finalize until shared understanding — so
  plan leaves zero decisions to executor. Invoked non-interactively
  unresolvable question stops planning run instead of being planned
  around.
- `radin-execute` excludes `.claude/.radin/` from every dirty-tree check and
  stash (`-- . ':(exclude).claude/.radin'`). In repo tracking
  namespace, orchestrator's own state writes previously read as dirty
  tree — sub-agents could fold radin state into task commits, and
  orchestrator could stash own state file. radin never commits its
  namespace: committing or ignoring `.claude/.radin/` stays consumer's
  call.
- `radin-execute` session-end residuals now always stashed, never
  auto-committed — deciding unknown changes belong in history is
  user's call. Phase 1's "no backlog found" questions end run with
  question as final report instead of waiting mid-run, task whose
  title no longer matches exactly one `###` heading marked `blocked`
  instead of guessing which entry meant.
- `radin-execute`'s orchestrator model bumped from `haiku` to `sonnet` —
  observed haiku failure modes (ending session on one decision,
  modeling itself as persistent process) cost whole sessions, far more
  than model delta on control-flow turns.
- `radin-execute` no longer invokes `radin-plan` unconditionally for
  unplanned task. First asks `/ponytail` whether task is
  straightforward enough to implement directly — only genuinely complex tasks go through `/radin-plan`.
- `radin-plan` now reviews each plan it writes with `/thermo-nuclear` and
  `/ponytail-review` before handing off, fixing findings directly in
  plan file — no separate backlog entry, plan hasn't executed yet.

- `radin-plan` now skill (`skills/radin-plan/SKILL.md`) instead of agent — runs inline in whichever context invokes it, so split
  judgment and any plan-review question surface directly instead of inside
  sub-agent's transcript. `radin-execute` delegates it to dedicated
  planning sub-agent for any task reaching execution with no `**Plan:**`
  line yet — no more ad-hoc inline planning duplicated in `radin-execute`'s
  own prompt. `lib/radin-planning.md` folded directly into skill, since
  it's now only caller. `BACKLOG_PLAN_STEPS.json` gone — skill
  re-resolves its sub-task list within conversation instead of
  persisting one to disk.
- `radin-plan` now takes single backlog entry as scope instead of
  processing whole backlog — point it at task title/keyword. Uses
  `/ponytail` to judge (defaulting to no) whether entry's scope should
  split into multiple independent sub-plans, confirms any split with
  user, then writes one plan file and `**Plan:**` line per resulting
  sub-task. `radin-execute` now follows one or more `**Plan:**` lines per
  entry in order. `docs/schemas/backlog-entry.schema.json`'s `plan` field
  now array of lines instead of single string.

### Added

- `skills/radin-record`: captures feedback, bugs, follow-ups, or ideas
  raised mid-session, logs as structured `BACKLOG.md` entries.
- Renamed `ISSUES.md` to `BACKLOG.md` throughout (file name, `$BACKLOG_FILE`
  variable, `BACKLOG_STEPS.json`/`BACKLOG_PLAN_STEPS.json` state files,
  `docs/schemas/backlog-entry.schema.json`) — backlog holds features and
  chores too, not only issues.
- `BACKLOG.md` now uses semver-style category sections (`feat`, `fix`,
  `chore`, `refactor` — same vocab as conventional-commit type)
  instead of ad-hoc per-entry tags. Applies to `radin-review`,
  `radin-record`, `radin-execute`, `radin-plan`. Adds
  `docs/schemas/backlog-entry.schema.json` as formal contract.
- `install.sh`: new optional prompt for
  [i-have-adhd](https://github.com/ayghri/i-have-adhd), installed same
  way as `caveman` (Claude Code plugin marketplace).
- `install.sh`: new optional prompt for
  [ponytail](https://github.com/DietrichGebert/ponytail), same plugin
  marketplace flow.

### Fixed

- `install.sh`: declining companion-tool prompt (`rtk`, `code-review-graph`,
  `caveman`) for tool not already installed silently killed rest of
  script under `set -e`. Bare `return` after failed `[ ]` test
  propagated that test's nonzero exit status. `install_if_confirmed` and
  `install_plugin_if_confirmed` now `return 0` explicitly on decline.
- CI (`.github/workflows/ci.yml`) referenced `sync.sh` that doesn't exist
  in this repo. Removed dead `bash -n`/`shellcheck`/drift-gate steps that
  depended on it.

### Added

- `tests/install.bats`: BATS suite for `install.sh` — source resolution from
  real checkout, agent/skill installation, `.radin` namespace/registry
  idempotency, companion-tool prompt gating, missing-Homebrew
  failure path. Runs in CI via new `test` job.

## [0.1.0] — 2026 (unreleased on GitHub)

Initial scaffold: `radin-execute` and `radin-plan` agents,
`radin-review` skill, `~/.claude/.radin/` storage namespace, and
`install.sh` with optional companion-tool installs (rtk, caveman,
code-review-graph).
