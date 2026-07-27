# Changelog

Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Changed

- `install.sh` installs the shared `lib/` scripts (`radin-backlog.sh`,
  `radin-namespace.sh`, `radin-prioritization.md`) to `~/.claude/.radin/lib/`
  instead of `~/.claude/radin-lib/`. Every agent/skill reference updated to
  match.

- `radin-execute` now runs the whole backlog in one turn. It delegates every
  task sub-agent synchronously (`run_in_background: false`) and waits for
  the result — it no longer spawns a background sub-agent and ends its turn,
  which left nobody listening for the completion.
- `radin-execute` never decides on the user's behalf. A task that needs a
  judgment call the entry or plan doesn't settle is marked `blocked` (new
  state-JSON status, next to `pending`/`failed`) with the question, options,
  and a recommendation — nothing is implemented for it, the rest of the
  backlog still runs, and the final summary asks the user to decide. The
  execution sub-agent got a matching `STATUS: BLOCKED` report line.
- `radin-execute` keeps its own context lean over long sessions: execution
  sub-agents are told to report a few lines plus the `STATUS:` line, and the
  state-persistence contract spells out recovery from disk after context
  compaction. Planning runs in its own sub-agent so its codebase exploration
  never lands in the orchestrator's context — the plan file on disk is the
  handoff to the execution sub-agent. That planning run is non-interactive:
  where `/radin-plan` would ask the user (split, overwrite) it takes the
  non-destructive path, and real ambiguity marks the task `blocked` instead
  of guessing.
- `radin-execute` re-locates each entry by its `### title` at the start of
  every task and refreshes `line_start`/`line_end` in the state file —
  earlier `**Plan:**` insertions shift line numbers, and stale spans meant
  reading the wrong entry text.
- `/radin-plan` invoked non-interactively no longer guesses on entry
  matching: several candidate matches, or no match at all (backlog drift),
  stop the planning run and mark the task `blocked` instead of picking one
  or creating a duplicate entry.
- `radin-execute`'s post-session review no longer asks for consent mid-run
  (as a sub-agent, nobody can answer it). A review runs only when the
  invoking prompt asked for one up front; otherwise the final summary ends
  with the `/radin-review` command the user can run themselves.
- `radin-execute` got two interaction modes. Interactive (the default)
  assumes the user is at the keyboard: the first open question stops the
  run — state flushed to disk, question + options + recommendation and
  progress so far in the report, re-invoking resumes from the state file.
  Autonomous (say "autonomously" when invoking) parks blocked tasks, keeps
  executing the rest, and batches every question into the final summary.
  Either way, an answer given on re-invocation is appended to the entry's
  description in `BACKLOG.md` so planning/execution sub-agents read it.
- `radin-plan` now front-loads clarification as an interview: invoked
  interactively it walks the entry's decision tree one question at a time,
  each with a recommended answer, looks up facts in the repo instead of
  asking them, and doesn't finalize until shared understanding — so the
  plan leaves zero decisions to the executor. Invoked non-interactively an
  unresolvable question stops the planning run instead of being planned
  around.
- `radin-execute` excludes `.claude/.radin/` from every dirty-tree check and
  stash (`-- . ':(exclude).claude/.radin'`). In a repo that tracks the
  namespace, the orchestrator's own state writes previously read as a dirty
  tree — sub-agents could fold radin state into task commits, and the
  orchestrator could stash its own state file. radin never commits its
  namespace: committing or ignoring `.claude/.radin/` stays the consumer's
  call.
- `radin-execute` session-end residuals are now always stashed, never
  auto-committed — deciding that unknown changes belong in history is the
  user's call. Phase 1's "no backlog found" questions end the run with the
  question as the final report instead of waiting mid-run, and a task whose
  title no longer matches exactly one `###` heading is marked `blocked`
  instead of guessing which entry was meant.
- `radin-execute`'s orchestrator model bumped from `haiku` to `sonnet` — the
  observed haiku failure modes (ending the session on one decision,
  modeling itself as a persistent process) cost whole sessions, far more
  than the model delta on control-flow turns.
- `radin-execute` no longer invokes `radin-plan` unconditionally for an
  unplanned task. It first asks `/ponytail` whether the task is
  straightforward enough to implement directly — only tasks judged genuinely
  complex go through `/radin-plan`.
- `radin-plan` now reviews each plan it writes with `/thermo-nuclear` and
  `/ponytail-review` before handing it off, fixing any findings directly in
  the plan file — no separate backlog entry, the plan hasn't executed yet.

- `radin-plan` is now a skill (`skills/radin-plan/SKILL.md`) instead of an
  agent — it runs inline in whichever context invokes it, so its split
  judgment and any plan-review question surface directly instead of inside
  a sub-agent's transcript. `radin-execute` delegates it to a dedicated
  planning sub-agent for any task that reaches execution with no `**Plan:**`
  line yet — no more ad-hoc inline planning duplicated in `radin-execute`'s
  own prompt. `lib/radin-planning.md` is folded directly into the skill, since
  it's now the only caller. `BACKLOG_PLAN_STEPS.json` is gone — the skill
  re-resolves its sub-task list within the conversation instead of
  persisting one to disk.
- `radin-plan` now takes a single backlog entry as its scope instead of
  processing the whole backlog — point it at a task title/keyword. It uses
  `/ponytail` to judge (defaulting to no) whether that entry's scope should
  split into multiple independent sub-plans, confirms any split with the
  user, then writes one plan file and `**Plan:**` line per resulting
  sub-task. `radin-execute` now follows one or more `**Plan:**` lines per
  entry in order. `docs/schemas/backlog-entry.schema.json`'s `plan` field is
  now an array of lines instead of a single string.

### Added

- `skills/radin-record`: captures feedback, bugs, follow-ups, or ideas
  raised mid-session and logs them as structured `BACKLOG.md` entries.
- Renamed `ISSUES.md` to `BACKLOG.md` throughout (file name, `$BACKLOG_FILE`
  variable, `BACKLOG_STEPS.json`/`BACKLOG_PLAN_STEPS.json` state files,
  `docs/schemas/backlog-entry.schema.json`) — the backlog holds features and
  chores too, not only issues.
- `BACKLOG.md` now uses semver-style category sections (`feat`, `fix`,
  `chore`, `refactor` — the same vocabulary as a conventional-commit type)
  instead of ad-hoc per-entry tags. Applies to `radin-review`,
  `radin-record`, `radin-execute`, and `radin-plan`. Adds
  `docs/schemas/backlog-entry.schema.json` as the formal contract.
- `install.sh`: new optional prompt for
  [i-have-adhd](https://github.com/ayghri/i-have-adhd), installed the same
  way as `caveman` (Claude Code plugin marketplace).
- `install.sh`: new optional prompt for
  [ponytail](https://github.com/DietrichGebert/ponytail), same plugin
  marketplace flow.

### Fixed

- `install.sh`: declining a companion-tool prompt (`rtk`, `code-review-graph`,
  `caveman`) for a tool not already installed silently killed the rest of
  the script under `set -e`. A bare `return` after a failed `[ ]` test
  propagated that test's nonzero exit status. `install_if_confirmed` and
  `install_plugin_if_confirmed` now `return 0` explicitly on decline.
- CI (`.github/workflows/ci.yml`) referenced a `sync.sh` that doesn't exist
  in this repo. Removed the dead `bash -n`/`shellcheck`/drift-gate steps that
  depended on it.

### Added

- `tests/install.bats`: BATS suite for `install.sh` — source resolution from
  a real checkout, agent/skill installation, `.radin` namespace/registry
  idempotency, companion-tool prompt gating, and the missing-Homebrew
  failure path. Runs in CI via a new `test` job.

## [0.1.0] — 2026 (unreleased on GitHub)

Initial scaffold: `radin-execute` and `radin-plan` agents,
`radin-review` skill, the `~/.claude/.radin/` storage namespace, and
`install.sh` with optional companion-tool installs (rtk, caveman,
code-review-graph).
