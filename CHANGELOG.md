# Changelog

Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## 1.0.0 (2026-08-05)


### Features

* add force mode for updates ([a4fd443](https://github.com/shortcuts/radin/commit/a4fd4434479903d0046e0209dc11f6eeada08f9b))
* add headroom as optional companion tool ([0d7d5cb](https://github.com/shortcuts/radin/commit/0d7d5cbf25174c715d751765f9424858119b633f))
* add i-have-adhd ([0e5e5a4](https://github.com/shortcuts/radin/commit/0e5e5a47cdfb48c229fd0b88fa2bf38a745da76d))
* add openai.yaml agent manifests to radin skills ([7c4047f](https://github.com/shortcuts/radin/commit/7c4047f435e12312e87752bd94732d5c1d6574ac))
* add ponytail ([1513547](https://github.com/shortcuts/radin/commit/1513547f9fea31f4186c438ffb8def102c8c366d))
* add radin-doctor install verification command ([74bb980](https://github.com/shortcuts/radin/commit/74bb980319940d2c2d362517c08d3482be47cd30))
* add radin-record skill ([656fe06](https://github.com/shortcuts/radin/commit/656fe06721949ba74e8a4cfc16fdb22d17dc1601))
* add radin-show skill to print current project's backlog ([9577a75](https://github.com/shortcuts/radin/commit/9577a75474ae0a8a586d3f3ac47eaba2fbb8c2fc))
* add radin-state.sh CLI, stop hand-editing execute's state JSON ([8404994](https://github.com/shortcuts/radin/commit/840499476ab6ebf78851abdc54c93641881d3fa6))
* add radin-stats skill ([3f4e1fd](https://github.com/shortcuts/radin/commit/3f4e1fd9c24491eb4eb1dbe72613b7c5a4170efd))
* add release-please automation ([532c601](https://github.com/shortcuts/radin/commit/532c601c11761178347ef8e5e53545f801d002ee))
* allow configuring model on agents ([729b1f7](https://github.com/shortcuts/radin/commit/729b1f7c7e9446fc8d5ca2848d0c81e45afa6793))
* decide rtk leverage and add sub-agent guidance ([6f6b61c](https://github.com/shortcuts/radin/commit/6f6b61cbb5969d7d24fbe008344f165abcb47fe3))
* dependency-aware task ordering and drift detection in radin-execute ([3d298b2](https://github.com/shortcuts/radin/commit/3d298b217abf7f35bf862fbacc4acc9c531d123f))
* gate planning on ponytail, self-review plans before handoff ([543a899](https://github.com/shortcuts/radin/commit/543a899f4125149839eee208c6b6b94e64d07fe2))
* leverage code-review-graph in radin-plan and radin-execute ([aa1e2f4](https://github.com/shortcuts/radin/commit/aa1e2f4ecf50fbb674496caf1bafabdf1940d17e))
* **lib:** add radin-backlog.sh CLI for deterministic backlog operations ([477b5ef](https://github.com/shortcuts/radin/commit/477b5efed8e3103a50e07226aefc707b14892bcf))
* radin stack ([debe84e](https://github.com/shortcuts/radin/commit/debe84e97a8edbe091d0c5148c8e2e0f7ba47e04))
* **radin-execute:** interactive vs autonomous interaction modes ([cf0eee3](https://github.com/shortcuts/radin/commit/cf0eee315bf1a19eb1741a75428696124cea09d0))
* **radin-execute:** sync orchestration, blocked status, sub-agent planning ([7a8a338](https://github.com/shortcuts/radin/commit/7a8a338705b0ec9b383a0124affcd1d114113808))
* **radin-plan:** delegate interview to /grilling, add /research for API facts ([23be4fb](https://github.com/shortcuts/radin/commit/23be4fbd97ed2bcb651d3e81ec6ba72ce6806487))
* split backlog storage into a JSONL index + one file per task ([192ef30](https://github.com/shortcuts/radin/commit/192ef3009f1556b4a8170270f52cae01b3667bdd))
* **uninstall:** add radin-uninstall skill and lib script ([2ca05f2](https://github.com/shortcuts/radin/commit/2ca05f26300aad1481581f1f2adb85322ed2e53f))
* vendor mattpocock-skills as a companion tool ([56c1d9b](https://github.com/shortcuts/radin/commit/56c1d9b80d4d61fbc5b7c77159bc63bd781692e0))
* write install manifest on every install.sh run ([11c3476](https://github.com/shortcuts/radin/commit/11c3476bfb84168514bacf961c7033aabd0a3f53))


### Bug Fixes

* **AGENTS.md:** expand companion-tool list to include all six tools ([dbc126d](https://github.com/shortcuts/radin/commit/dbc126d4ecee99413d024f30ee0fc829dea216d8))
* **AGENTS.md:** remove outdated repo-root BACKLOG.md section ([7001e00](https://github.com/shortcuts/radin/commit/7001e00479a2c81fd8b80611743c5aaebdccdc92))
* backlog path simplification ([76cb098](https://github.com/shortcuts/radin/commit/76cb098f36a54f9cb0eda37a73b1652b0339bc94))
* **BACKLOG:** improve find file logic ([d0070f6](https://github.com/shortcuts/radin/commit/d0070f6123c702ca33520513bb1a5934ace08b32))
* check namespaced ISSUES_FILE before repo-root fallback ([c1c144f](https://github.com/shortcuts/radin/commit/c1c144ff91cfd6c354f1f3f8019e151816c1b65c))
* commit orchestrator rename ([0f8f0af](https://github.com/shortcuts/radin/commit/0f8f0afe4f9862ad685ed1ee52521ab846129869))
* curl | bash install silently dies on read prompts ([f7b037c](https://github.com/shortcuts/radin/commit/f7b037cb7b7c76dd883df672383ecc51bd8c7baa))
* execute should ask for a confirmation ([ac797c0](https://github.com/shortcuts/radin/commit/ac797c01aba720fce4b7611e6c782df224f3d646))
* **execute:** force hard stop ([685ee1e](https://github.com/shortcuts/radin/commit/685ee1e7cf3a2b54b8568d01b30615f98f16506f))
* headroom ([c9ee0d5](https://github.com/shortcuts/radin/commit/c9ee0d5ac1782883e5f948912b25c50762af9f73))
* install ([dd5bf4b](https://github.com/shortcuts/radin/commit/dd5bf4b18e022ce45d4fefe0ba75b862cc17d3cd))
* install requirements on python ([49ec94b](https://github.com/shortcuts/radin/commit/49ec94b73ffacda3d06d406ad9a1c734f99484e8))
* interactive plan ([daf12fa](https://github.com/shortcuts/radin/commit/daf12fa3cdaa927171c6aa693fb3470a944e5185))
* invoke sub skill ([1abef43](https://github.com/shortcuts/radin/commit/1abef43490bf066adb58cbf6a25e06d3c752c2a3))
* keep skill when recorded ([f0e1a5d](https://github.com/shortcuts/radin/commit/f0e1a5d2876e31e34e7b02e82a04b307bcff8ae6))
* less assumptions ([717d6fe](https://github.com/shortcuts/radin/commit/717d6fea075116c75ac861878b5ed8f1fc94ed1e))
* lib location ([731cb9a](https://github.com/shortcuts/radin/commit/731cb9abab88019f413c730e2550a1d0b926fe45))
* lint ([f045cfd](https://github.com/shortcuts/radin/commit/f045cfdba064aa62307457cd4fe628bc1bafed14))
* lint ([fb28845](https://github.com/shortcuts/radin/commit/fb28845c48be9c641fae5d72c758f5e73fd09e87))
* orchestrator must not leave dirty working tree ([266ef6d](https://github.com/shortcuts/radin/commit/266ef6de5d337c115a28a6398e93e0cc4f56fbda))
* orphaned backlog items ([51ab430](https://github.com/shortcuts/radin/commit/51ab430e67f8979fc54e74ad81000bdb1d235e65))
* **plan:** add record autonomously ([1821b8c](https://github.com/shortcuts/radin/commit/1821b8c116a4c262f6c76d62d2f6f85ec58369d0))
* **radin-execute:** add fallback for caveman-commit when plugin absent ([b01a5f3](https://github.com/shortcuts/radin/commit/b01a5f3eb9d8084fa50bb4b9f4ce487e26df289f))
* **radin-execute:** close non-interactive gaps in loop, planning, review ([d5edf54](https://github.com/shortcuts/radin/commit/d5edf54e2cf45ec6c4ac1c052ceaa8166a7f903e))
* **radin-execute:** correct Phase 4/5 references and typo ([3c514a9](https://github.com/shortcuts/radin/commit/3c514a98fb7fb9e4a0d34f952f792b3c2da5a51b))
* **radin-execute:** forbid inventing work when backlog missing or exhausted ([678da0f](https://github.com/shortcuts/radin/commit/678da0f1eee9f7eee05e3820e97a009339cf0953))
* **radin-execute:** keep radin namespace out of tree checks, close ask-path gaps ([6c985b8](https://github.com/shortcuts/radin/commit/6c985b8405efe8116563aaf3c3cca14f74498e78))
* **radin-execute:** remove completed entries from BACKLOG.md immediately ([7a6e4d7](https://github.com/shortcuts/radin/commit/7a6e4d7a85b0107514ab7e7632e2096b2cb7b06e))
* **radin-execute:** stash dirty trees instead of stranding them, report failures with recovery steps ([ab17ab0](https://github.com/shortcuts/radin/commit/ab17ab0d91051a7bf7d0a5f028af52c905bdfbb6))
* **radin-execute:** verify backlog existence mechanically, not by inference ([80f90a4](https://github.com/shortcuts/radin/commit/80f90a48722f285fe753e8599f9c889aaeec5943))
* **README:** correct radin-execute leverage table to show /radin-review ([c551636](https://github.com/shortcuts/radin/commit/c551636a4592f228ee4b6b1ed07c1d7945a3e953))
* redundant ISSUES.md file ([e07a7af](https://github.com/shortcuts/radin/commit/e07a7afa0c1891c986530208bf455043fb733562))
* remove orphan items from the backlog ([72027f5](https://github.com/shortcuts/radin/commit/72027f5636b390a17b420a05988649d7722043bc))
* silent install mode ([948644f](https://github.com/shortcuts/radin/commit/948644ff898e6368b93e6ec4fcc26e0673033d50))
* stats skill ([c8d037b](https://github.com/shortcuts/radin/commit/c8d037bdbf2c778a3f3d22144b6ad29f6f39c528))
* stop biasing orchestrator/plan agents toward repo-root ISSUES.md ([582cbbc](https://github.com/shortcuts/radin/commit/582cbbcbe76ac31e0147a882fcddf929e9a404d1))
* tests ([a803bb6](https://github.com/shortcuts/radin/commit/a803bb6abaadcb6b2ca9d05f0cc27947159f52f2))
* tests without homebrew ([95bd9b3](https://github.com/shortcuts/radin/commit/95bd9b330c1932cfc7133f8d0bf1533a22e8c7c7))
* **thermo-nuclear:** allow model invoke ([78d7779](https://github.com/shortcuts/radin/commit/78d777958abe5afa21528c4b07e2717e88df8b16))

## [Unreleased]

### Removed

- `install.sh` no longer offers `i-have-adhd` as an optional companion
  tool. Dropped from the manifest, `radin-doctor`, and `radin-uninstall`
  advisories. Already-installed plugins stay untouched — remove them
  yourself with `claude plugin uninstall i-have-adhd@i-have-adhd`.

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
