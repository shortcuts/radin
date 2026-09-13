# Changelog

Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

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
