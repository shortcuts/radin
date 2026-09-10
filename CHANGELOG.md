# Changelog

Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## 1.0.0 (2026-09-10)


### ⚠ BREAKING CHANGES

* **install:** headroom installs on a single yes
* remove the radin-execute-background agent
* **radin-execute-background:** rename from -detached, trim the prose
* **radin-execute:** ship as skill, not agent

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
* **backlog:** env --export prints source-able export lines ([16f530b](https://github.com/shortcuts/radin/commit/16f530bfdb5f5d89dcc39b2c4810e374c260b5e8))
* better agent granularity ([bbd74e7](https://github.com/shortcuts/radin/commit/bbd74e72c9f4e9fc9ddaefb476af94b59290a1fc))
* confirm order and worktree/branch via fixed choices ([8bd82d8](https://github.com/shortcuts/radin/commit/8bd82d88372179740892447c91f0002c6d0c9011))
* decide rtk leverage and add sub-agent guidance ([6f6b61c](https://github.com/shortcuts/radin/commit/6f6b61cbb5969d7d24fbe008344f165abcb47fe3))
* dependency-aware task ordering and drift detection in radin-execute ([3d298b2](https://github.com/shortcuts/radin/commit/3d298b217abf7f35bf862fbacc4acc9c531d123f))
* gate planning on ponytail, self-review plans before handoff ([543a899](https://github.com/shortcuts/radin/commit/543a899f4125149839eee208c6b6b94e64d07fe2))
* **install:** ask whether radin-execute may run sub-agents in parallel ([1cc2f57](https://github.com/shortcuts/radin/commit/1cc2f57371992309f7bf574d66ff4568f7e2c0ac))
* **install:** headroom installs on a single yes ([de116bf](https://github.com/shortcuts/radin/commit/de116bf3685a8a79a62330b13c2a7bdf734850de))
* **install:** one-pick shortcut for sub-agent models ([83dd65b](https://github.com/shortcuts/radin/commit/83dd65bc6e751beec04215b8e48636d2d9a947fe))
* **install:** opt-in radin guidance block in ~/.claude/CLAUDE.md ([e8b0b0c](https://github.com/shortcuts/radin/commit/e8b0b0cc4ba706c2550f56f0a694e03d0c8b6dde))
* **install:** RADIN_CLI token replaces hardcoded CLI invocations ([38b0062](https://github.com/shortcuts/radin/commit/38b0062a4f4c6c90fa1488ce53d392a293fae955))
* leverage code-review-graph in radin-plan and radin-execute ([aa1e2f4](https://github.com/shortcuts/radin/commit/aa1e2f4ecf50fbb674496caf1bafabdf1940d17e))
* **lib:** add radin-backlog.sh CLI for deterministic backlog operations ([477b5ef](https://github.com/shortcuts/radin/commit/477b5efed8e3103a50e07226aefc707b14892bcf))
* offload deterministic logic from agents/skills to CLIs ([bd57713](https://github.com/shortcuts/radin/commit/bd5771399a3302eebc9a059ed0c470ec6ae4bef7))
* radin CLI dispatcher, quiet companion installs ([3f60a9f](https://github.com/shortcuts/radin/commit/3f60a9f81193eb4c74704048b45c6c67f98df01b))
* radin stack ([debe84e](https://github.com/shortcuts/radin/commit/debe84e97a8edbe091d0c5148c8e2e0f7ba47e04))
* **radin-execute-detached:** opt-in agent for background backlog runs ([3cfcb6a](https://github.com/shortcuts/radin/commit/3cfcb6a9237c489a2686c38c80d2c4ef274828e2))
* **radin-execute:** interactive vs autonomous interaction modes ([cf0eee3](https://github.com/shortcuts/radin/commit/cf0eee315bf1a19eb1741a75428696124cea09d0))
* **radin-execute:** sync orchestration, blocked status, sub-agent planning ([7a8a338](https://github.com/shortcuts/radin/commit/7a8a338705b0ec9b383a0124affcd1d114113808))
* **radin-execute:** verify a SUCCESS, diagnose a FAILED ([7b0e739](https://github.com/shortcuts/radin/commit/7b0e73967cca4096d8fd5c6a4bfd9be29a6d5be4))
* **radin-plan:** delegate interview to /grilling, add /research for API facts ([23be4fb](https://github.com/shortcuts/radin/commit/23be4fbd97ed2bcb651d3e81ec6ba72ce6806487))
* **radin-record:** grill open decisions at record time ([c9cb7e4](https://github.com/shortcuts/radin/commit/c9cb7e423a1b2a4d43f8886b03ad4aac5fc11e92))
* remove the radin-execute-background agent ([a709abc](https://github.com/shortcuts/radin/commit/a709abc3e9e4ff5b95a7c2095da4af1e7a8cc8ee))
* simplify install helper ([b5b939b](https://github.com/shortcuts/radin/commit/b5b939b6232a3608e0cb8e152e39d363898e060d))
* split backlog storage into a JSONL index + one file per task ([192ef30](https://github.com/shortcuts/radin/commit/192ef3009f1556b4a8170270f52cae01b3667bdd))
* **state:** recover tasks a killed session left mid-flight ([60ba6c7](https://github.com/shortcuts/radin/commit/60ba6c781b769b4f60368148c0ba9bd8cf8f5059))
* **uninstall:** add radin-uninstall skill and lib script ([2ca05f2](https://github.com/shortcuts/radin/commit/2ca05f26300aad1481581f1f2adb85322ed2e53f))
* vendor mattpocock-skills as a companion tool ([56c1d9b](https://github.com/shortcuts/radin/commit/56c1d9b80d4d61fbc5b7c77159bc63bd781692e0))
* wire code-review-graph through radin's own merge-only script ([b4a8087](https://github.com/shortcuts/radin/commit/b4a8087103105d80bed26660481b73ee6dbdc5e7))
* write install manifest on every install.sh run ([11c3476](https://github.com/shortcuts/radin/commit/11c3476bfb84168514bacf961c7033aabd0a3f53))


### Bug Fixes

* **AGENTS.md:** expand companion-tool list to include all six tools ([dbc126d](https://github.com/shortcuts/radin/commit/dbc126d4ecee99413d024f30ee0fc829dea216d8))
* **AGENTS.md:** remove outdated repo-root BACKLOG.md section ([7001e00](https://github.com/shortcuts/radin/commit/7001e00479a2c81fd8b80611743c5aaebdccdc92))
* backlog path simplification ([76cb098](https://github.com/shortcuts/radin/commit/76cb098f36a54f9cb0eda37a73b1652b0339bc94))
* **BACKLOG:** improve find file logic ([d0070f6](https://github.com/shortcuts/radin/commit/d0070f6123c702ca33520513bb1a5934ace08b32))
* better leverage grilling sessions ([65bc7e4](https://github.com/shortcuts/radin/commit/65bc7e46e3bbd791579ec6755965e0aa5a807940))
* check namespaced ISSUES_FILE before repo-root fallback ([c1c144f](https://github.com/shortcuts/radin/commit/c1c144ff91cfd6c354f1f3f8019e151816c1b65c))
* CLAUDE.md ([3c5da6f](https://github.com/shortcuts/radin/commit/3c5da6f072fb3965c14f567bbf2f8518127646ef))
* commit orchestrator rename ([0f8f0af](https://github.com/shortcuts/radin/commit/0f8f0afe4f9862ad685ed1ee52521ab846129869))
* correct two wrong claims about sub-agent tool pools ([0ccbb50](https://github.com/shortcuts/radin/commit/0ccbb5047fa5b8ef32c42017e3accff3edf5e146))
* curl | bash install silently dies on read prompts ([f7b037c](https://github.com/shortcuts/radin/commit/f7b037cb7b7c76dd883df672383ecc51bd8c7baa))
* do not execute sub skill right away ([94244a4](https://github.com/shortcuts/radin/commit/94244a4ad1caff9b1728476990c236555671c2dd))
* dynamic workflows ([a22a8e9](https://github.com/shortcuts/radin/commit/a22a8e97891ab82fea86520b711e5037498d91e7))
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
* **prompts:** reconcile every sub-agent claim with the verified tool pool ([d573bf4](https://github.com/shortcuts/radin/commit/d573bf4211f9e7d7604d48ce0e4570ae62091b94))
* properly track worktree/branch ([2143342](https://github.com/shortcuts/radin/commit/21433425dd53318216cf2ca2231f42bfece9328f))
* **radin-execute:** add fallback for caveman-commit when plugin absent ([b01a5f3](https://github.com/shortcuts/radin/commit/b01a5f3eb9d8084fa50bb4b9f4ce487e26df289f))
* **radin-execute:** close non-interactive gaps in loop, planning, review ([d5edf54](https://github.com/shortcuts/radin/commit/d5edf54e2cf45ec6c4ac1c052ceaa8166a7f903e))
* **radin-execute:** correct Phase 4/5 references and typo ([3c514a9](https://github.com/shortcuts/radin/commit/3c514a98fb7fb9e4a0d34f952f792b3c2da5a51b))
* **radin-execute:** forbid inventing work when backlog missing or exhausted ([678da0f](https://github.com/shortcuts/radin/commit/678da0f1eee9f7eee05e3820e97a009339cf0953))
* **radin-execute:** keep radin namespace out of tree checks, close ask-path gaps ([6c985b8](https://github.com/shortcuts/radin/commit/6c985b8405efe8116563aaf3c3cca14f74498e78))
* **radin-execute:** remove completed entries from BACKLOG.md immediately ([7a6e4d7](https://github.com/shortcuts/radin/commit/7a6e4d7a85b0107514ab7e7632e2096b2cb7b06e))
* **radin-execute:** stash dirty trees instead of stranding them, report failures with recovery steps ([ab17ab0](https://github.com/shortcuts/radin/commit/ab17ab0d91051a7bf7d0a5f028af52c905bdfbb6))
* **radin-execute:** stop hanging on skills a sub-agent can't run ([cefe5c3](https://github.com/shortcuts/radin/commit/cefe5c34bbe4300493700732246cfaab60cfc27f))
* **radin-execute:** verify backlog existence mechanically, not by inference ([80f90a4](https://github.com/shortcuts/radin/commit/80f90a48722f285fe753e8599f9c889aaeec5943))
* **radin-record,radin-execute:** grill decisions at record time, checkpoint huge backlogs ([379901d](https://github.com/shortcuts/radin/commit/379901de915464cec9dba3d684211b7bbc658c4a))
* **radin-record:** quote the raising text verbatim in the entry body ([b81d5eb](https://github.com/shortcuts/radin/commit/b81d5eb9b2fb65292e0cb9bf801dc4151e9c3954))
* **radin-review:** confine findings to the resolved scope ([624158e](https://github.com/shortcuts/radin/commit/624158e3902de7588225622e5482ab9717a7a114))
* **README:** correct radin-execute leverage table to show /radin-review ([c551636](https://github.com/shortcuts/radin/commit/c551636a4592f228ee4b6b1ed07c1d7945a3e953))
* redundant ISSUES.md file ([e07a7af](https://github.com/shortcuts/radin/commit/e07a7afa0c1891c986530208bf455043fb733562))
* remove orphan items from the backlog ([72027f5](https://github.com/shortcuts/radin/commit/72027f5636b390a17b420a05988649d7722043bc))
* review ([5742c4d](https://github.com/shortcuts/radin/commit/5742c4d407cb16f2977f4b633989c8352c7caf94))
* review pick process ([cf5c534](https://github.com/shortcuts/radin/commit/cf5c534ce5e5cebbb48bf4733909a66066a93916))
* review with grilling ([a950932](https://github.com/shortcuts/radin/commit/a950932558a6da4eb7d120f7dc6582662fc0d4dc))
* scripts ([df57a9c](https://github.com/shortcuts/radin/commit/df57a9cafcd90f40c9d81e6851cad9a583c95929))
* silent install mode ([948644f](https://github.com/shortcuts/radin/commit/948644ff898e6368b93e6ec4fcc26e0673033d50))
* stats skill ([c8d037b](https://github.com/shortcuts/radin/commit/c8d037bdbf2c778a3f3d22144b6ad29f6f39c528))
* stop biasing orchestrator/plan agents toward repo-root ISSUES.md ([582cbbc](https://github.com/shortcuts/radin/commit/582cbbcbe76ac31e0147a882fcddf929e9a404d1))
* strict execute instructions ([02b9fce](https://github.com/shortcuts/radin/commit/02b9fce2fdfaba286134e3c3ae4eba4a499cb456))
* tests ([a803bb6](https://github.com/shortcuts/radin/commit/a803bb6abaadcb6b2ca9d05f0cc27947159f52f2))
* tests without homebrew ([95bd9b3](https://github.com/shortcuts/radin/commit/95bd9b330c1932cfc7133f8d0bf1533a22e8c7c7))
* **thermo-nuclear:** allow model invoke ([78d7779](https://github.com/shortcuts/radin/commit/78d777958abe5afa21528c4b07e2717e88df8b16))
* update path ([18e3c59](https://github.com/shortcuts/radin/commit/18e3c59c537901d681898ae31013da3e31356f8d))


### Code Refactoring

* **radin-execute-background:** rename from -detached, trim the prose ([634b1f1](https://github.com/shortcuts/radin/commit/634b1f18c2b1babcde2eed00efc877e3486f3e41))
* **radin-execute:** ship as skill, not agent ([020204e](https://github.com/shortcuts/radin/commit/020204ebf658bf4eaa1bc8904895db7989391ae9))

## [Unreleased]

### Added

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

### Changed

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
