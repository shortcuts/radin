# Changelog

Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

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
