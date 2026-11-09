# radin Agent Reference

radin is a Claude Code plugin of skills, a CLI, and install glue.

## Hard rules

- **bash 3.2** (macOS ships it). Use no associative arrays, `mapfile`, or `${var,,}`. Add no `uname` branch. Resolve tools with `command -v` or `brew shellenv`. Branch only where a tool differs (`md5` versus `md5sum`). Call out every script edit.
- **`~/.claude` is not ours.** `~/.radin` is. `install.sh` writes `.sh`, `.c` and `.txt` only under `~/.radin/lib` and `.md` only under `~/.radin/hosts/<host>/lib`. It runs `cp` only on radin's own named files, plus `mkdir -p`. It never runs `rm`, deletes with a wildcard, or overwrites a file radin does not ship. Nine exceptions:
  1. The `<!-- radin:begin -->`…`<!-- radin:end -->` block in `~/.claude/CLAUDE.md`.
  2. The `radin wire` snapshot (kept in `~/.radin/backups`) and restore of `settings.json` and `~/.claude.json`.
  3. `skills/unslop/SKILL.md` and `skills/technical-writing/SKILL.md`. `install.sh` fetches both from upstream and overwrites them only when `manifest.json` lists them as radin's own. It also writes the skills of `lib/companion-skills.txt` into `~/.agents/skills`, and overwrites one only when `manifest.json` lists it in `agents_skills`.
  4. `skills/radin-execute`, `skills/radin-implement` and `skills/radin-run`, renamed to `radin-batch` and `radin-do`. `install.sh` removes one only when its `SKILL.md` still has radin's own `name:` line.
  5. `skills/thermo-nuclear`. `install.sh` removes it only when the fresh `thermo-nuclear-code-quality-review` copy is ready. `tests/bash-compat.bats` pins that one `rm`.
  6. `.ponytail-band`. `install.sh` writes `off` only when the file is absent, so ponytail's band starts hidden.
  7. Two `Read(//…/.radin/**)` strings in `permissions.allow` of `settings.json`. `cbm::allow` adds them and `cbm::unallow` removes exactly those strings and the two legacy `Read(//…/.claude/.radin/**)` ones. `cbm::unallow_legacy` removes the legacy pair alone, after a migration. No other key or rule changes ([why](docs/agents/DECISIONS.md#platform-and-install)).
  8. `~/.claude/.radin`. `install.sh` moves it once to `~/.radin` with `mv`, only when it holds a radin manifest, through `~/.radin.migrating`. A foreign `~/.radin` or a leftover staging directory aborts before any write ([why](docs/agents/DECISIONS.md#platform-and-install)).
  9. `--force` moves an unowned or edited radin-named path to `~/.radin/backups` with `mv`, then installs radin's file. It runs no `rm` there. Without `--force` that path stops its host or stays as the user left it ([why](docs/agents/DECISIONS.md#platform-and-install)).

  Call out every `install.sh` edit.
- **Companion install is advisory.** A failed install prints a warning and the run continues. The installer asks one question: which package manager installs the companions (`brew`, `mise`, or `curl`). radin adds no package manager the user has not already run.
- **Tests never touch the real device setup.** No test reads or writes the real `~/.claude`, `~/.config/.claude`, `~/.claude.json`, `~/.codex`, `~/.config/opencode`, the `CLAUDE_CONFIG_DIR`, `CODEX_HOME` or `OPENCODE_CONFIG` target or the keychain. Tests use mocks and stubs under an isolated `HOME`, `XDG_CONFIG_HOME` and `CODEX_HOME`.

## Rule enforcers

| Rule | Enforcer | Gap |
| --- | --- | --- |
| bash 3.2 | `tests/bash-compat.bats` | Grep only; no 3.2 interpreter run. |
| `~/.claude` ownership | `tests/cbm_config.rs` and `src/cbm/config.rs` (`allow` keeps foreign rules, follows a symlink, `unallow` removes only radin's), `tests/install*.bats` ("never overwrites a skill radin did not install", the agents companion skill cases), `tests/bash-compat.bats` (`rm` allowlist), `SHIPPED` (install copies and uninstall removes only listed names) | Foreign content in the `CLAUDE.md` block and settings restore is untested. |
| Migration of `~/.claude/.radin` aborts before any write | `tests/install*.bats` (foreign `~/.radin`, failed `mv`, leftover staging directory, half-migrated, symlinked `~/.claude`, old updater) | An interrupted copy on a real second device is untested. |
| Rendered `.md` only under `~/.radin/hosts/<host>/lib` | `tests/install*.bats` layout test, `tests/shipped.rs` (`lib` versus `hostlib` kinds) | None. |
| One list of shipped files | `tests/shipped.rs`, run by `make check` | README row text is hand-written. |
| Install changes only paths radin owns | `tests/install*.bats` (the unowned, edited and `--force` tests) | A foreign file inside a radin skill directory is overlaid, not checked. |
| A forbid hit stops one host | `tests/install*.bats` (the claude and agents render-failure tests) | None. |
| Companion install is advisory | `tests/install*.bats` ("a failing companion tool...") | None. |
| One owner per delegation | `tests/lints.rs` (every name resolves) | Nothing for "one file per delegation" and graph tool names; review only. |
| One owner per prose rule | `LEAF_CONTRACT`, `EXPLORE_RULE`, `OPEN_DECISIONS_RULE` and `PLANNING_RULE` tokens, `tests/lints.rs` (new verbatim sentence copy) | A paraphrase or contradiction; review only. |
| Name each companion directly, no guard or escape clause | `tests/lints.rs` guard phrases | A paraphrase escapes the phrase list. |
| A test must be able to fail | `tests/lints.rs` bare `! cmd` lint | Other vacuous patterns; review only. |
| Tests never touch the real device setup | `make test` runs bats with `CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `XDG_CONFIG_HOME` and `OPENCODE_CONFIG` unset and fails when `scripts/real-setup-sum.sh` differs before and after; `tests/helpers/isolate.bash` isolates each file | A test that reads the keychain or another real path; review only. |
| `RADIN_HOST` selects skill names, never a state dir | `tests/host.bats` | None. |
| Legacy `.claude/.radin` and `.agents/.radin` migrate into `.radin` without loss | `tests/migrate.bats` | A crash between the copy and the rename is untested. |
| `.gitignore` gets `.radin/` once | `tests/migrate.bats` | None. |
| `radin doctor` checks every installed host | `tests/doctor.bats` | The real CLI probes (Codex `/hooks`, opencode version) run against stubs. |
| `radin uninstall` removes only bytes radin still owns | `tests/uninstall.bats`, the three-host lifecycle test in `tests/install*.bats` | Foreign text inside a radin block is stripped with it. |
| The agents render names no Claude-only tool and holds no model line | `hosts/forbid-agents.txt`, `tests/lints.rs` forbid lint, `tests/render-host.bats` | A paraphrase of a tool name; review only. |
| Every host path variable is isolated | `tests/isolation.bats`, `tests/real-setup-sum.bats` | None. |
| A three-host lifecycle leaves no radin file | The three-host lifecycle test in `tests/install*.bats` | The real CLIs are not run; `make verify-hosts` owns that. |
| Real CLIs load radin's files | `make verify-hosts` (opt-in) and `tests/verify-hosts.bats` | Linux and opencode 1.x unverified; opencode skills are a file check only. |
| `--dry-run` changes nothing | `tests/install*.bats` ("--dry-run lists the writes the real run makes and changes nothing") | Companion command text is printed, not run. |
| Install asks every question before the first write | `tests/install*.bats` wizard cases (forward, back, checkbox, `--update` Recap, `--yes` and `STEP_TOTAL`) | A terminal that rejects raw mode falls back to numbered prompts with no back; review only. |
| A selected host with no CLI still installs | `tests/install*.bats` ("every selected host installs its files when no host CLI exists") | None. |
| `radin update` keeps a failed host in the manifest | `tests/install*.bats` ("--update leaves a host whose render fails untouched...") | None. |
| Same checks locally and in CI | `make check` and `make test` in `.github/workflows/ci.yml` | Linux run unverified. |
| Deterministic work lives in the CLI | `tests/lints.rs` raw `git` lint over `lib/radin-run.md` and `lib/radin-batch-*.md` | Other deterministic steps in prose, and a raw `git` outside those files; review only. |
| No namespaced companion name outside the table | `tests/lints.rs` name lint (`.sh` literals, tokens missing from a table) and its skill-name tests | A bare name written without a slash; review only. |
| Host-specific text lives in host blocks | `scripts/render-host.sh` (marker errors, surviving forbidden string) and the `tests/lints.rs` forbid lint with `hosts/forbid-baseline.txt` | A Claude-only idea worded with no forbidden string; review only. |
| Lifecycle diagrams match the skills and the run loop | None; `make diagrams` regenerates the SVGs | Review only. |
| Claude render unchanged | `tests/install*.bats` golden render test, `make golden` | Files outside `SKILL.md` and `lib/*.md` are unhashed. |

Add a row with every new hard rule.

## Where to edit what

| Change | Edit |
| --- | --- |
| A host difference in a skill or lib file | A `<!-- host:NAME -->` block in the source. A forbidden string goes in `lib/forbid-<host>.txt`. A companion skill name is `@@skill:NAME@@` in prose and `radin_skill NAME` in a script, spelled by `lib/skill-names-<host>.txt`. |
| A skill's behavior | `skills/<name>/SKILL.md`, never the installed copy. |
| Anything deterministic (install, update, doctor, uninstall, backlog, state, TUI) | A `bin/radin` subcommand in `lib/`, never a skill. |
| Backlog loop of `radin-batch` and `radin-do` | `lib/radin-run.md`. |
| Rare-need part of `radin-batch` | `lib/radin-batch-*.md`, read on demand. |
| A constraint, a decision, or a rule with its reason | `docs/agents/DECISIONS.md`, one bullet: the rule, then `**Why:**`. No layout, verb list or format table: the code and the graph hold those. |
| A skill's flow, a `radin-run.md` phase, a leaf step, or a task status | `docs/agents/lifecycle/*.mmd`, then `make diagrams` ([diagrams](docs/agents/lifecycle.md)). Commit the `.mmd` and `.svg` together. |
| The README screenshot | `make screenshot`, then commit `docs/img/tui.svg`. |
| What ships, a renamed or removed skill or lib file | `SHIPPED`, then `make gen` ([how](docs/agents/DECISIONS.md#platform-and-install)). |
| Sub-agent model, CLI invocation | Nothing. Write a token and `install.sh` resolves it ([how](docs/agents/DECISIONS.md#platform-and-install)). |

A new skill also needs a README row. `make check` names any step you missed.

A new companion that ships stats or a gain command needs a bullet in `skills/radin-stats/SKILL.md`.

## Storage

The state directory is `<repo-root>/.radin/`, under `$PWD`, shared by every host. It holds `backlog/` (`index.jsonl` and `tasks/<id>.md`), `state/`, `plans/`, and `reviews/` ([rules](docs/agents/DECISIONS.md#state-and-data)). It is the only thing radin writes into a consumer repo, plus one `.radin/` line appended to `.gitignore` on the run that creates or migrates it.

Read and write it only through the CLI (`radin backlog …`, `radin state …`). No code parses `index.jsonl` or `completed.json`, or grabs a task by line number. When no subcommand gives the view you need, add one.

The global telemetry store `~/.radin/telemetry/` is written only through `radin telemetry record` and `radin telemetry report-error`.

## Skills, agents, sub-agents

Every entry point is a skill, because only a skill runs in the user's thread and can talk to the user. A sub-agent is a leaf worker that a skill dispatches. It cannot write prose to the user, call `AskUserQuestion`, or receive a background-task notification.

- Before a prompt points at a skill, check that the skill asks the user nothing and spawns no agent ([constraints](docs/agents/DECISIONS.md#skills-and-sub-agents)).
- Name each companion directly, with no `command -v` gate and no escape clause. A missing tool fails loudly and counts as a skip.
- The one guard that stays is a skill that asks a human anything. A sub-agent drops it and never waits on it.

## Autonomy

Routers and sub-agents proceed on reversible work without asking: code edits, notes, task splits, backlog entries, anything `git revert` or deleting a file radin wrote undoes. Irreversible work pauses: force-push, deploy, data deletion, external messages.

- A skill in the user's thread asks the user first.
- A sub-agent stops and reports `STATUS: BLOCKED (DECISION)` with the question, the options, and its recommendation. It never skips the task.
- The human owns product direction. A sub-agent that meets a product choice reports it and does not pick.
- Asked to add scope, an agent gives its real judgment. "No" is a valid reply. Agreement it does not hold is not.

## Writing prose for agents

Applies to `skills/*/SKILL.md`, `lib/radin-*.md`, and this file. Style source: [cursor/plugins `pstack/skills`](https://github.com/cursor/plugins/tree/main/pstack/skills).

- **No-op test.** Delete a whole sentence that does not change what the model does. Never trim one word out of it. Measure disputed cases ([how](CONTRIBUTING.md#measure-a-prose-edit)).
- **Positive over prohibition.** State the target behavior. Keep a prohibition only as a hard guardrail with no positive form, and pair it with the target.
- **Start at the job.** Open with the task or step 1.
- **Description is a trigger.** Start "Use for" or "Apply when".
- **Every sentence carries a value:** a flag, a field, a default, a fallback, or a decision rule.
- **Bold lead phrase, one imperative sentence.** Add `**Why:**` only when the rule looks wrong without it.
- **One yes/no `**The test:**` per judgment call.**
- **Process skills:** verb-titled phases, ending with `**Reply:**` (what the user gets back).
- **Name another skill. Never restate it** ([one rule, one file](docs/agents/DECISIONS.md#one-rule-one-file)).
- **Use the short, exact word,** one term per concept. Keep "the", "a", "not", "only". Skip em dashes, colon connectors, metaphor nouns, and "simply".
- **A cut never adds words.** Compare `wc -w` before and after. When no sentence fails the no-op test, leave the file unchanged.

More rules: `/mattpocock-skills:writing-for-agents`, the `STE` output style, `unslop` (human-facing prose), `technical-writing` (docs, READMEs, PR and commit text).

## Delegation: one owner per job

When a shipped tool does a job, name that tool. Never write a radin version. Name each delegation in one file ([a test pins every name](docs/agents/DECISIONS.md#skills-and-sub-agents)).

| Job | Owner |
| --- | --- |
| Settle a decision · API facts · module boundaries · diagnose a failure | `/mattpocock-skills:grilling` · `:research` · `:codebase-design` · `:diagnosing-bugs` |
| Minimal change · over-engineering · debt ledger | `/ponytail:ponytail` · `-review`/`-audit` · `-debt` |
| Maintainability review · commit message | `/thermo-nuclear` · `/caveman:caveman-commit` |
| Implementation discipline | `/caveman:surgical-patch` (fix), `safe-refactor`, `lean-build` (feat) |
| Code structure questions | codebase-memory-mcp's MCP tools |
| Output compression | `rtk` |
| Agent-doc writing rules | `/mattpocock-skills:writing-for-agents` |

The graph tool name lives in one file and must exist in the upstream table ([which files, and the pointer rule](docs/agents/DECISIONS.md#limits-of-the-codebase-memory-mcp-bracket)).

## Decisions that look like bugs

- **No router-side per-task verification in `radin-batch`.** The leaf verifies and reviews its own staged diff before it commits. A `FAILED` task gets a Debug prompt once per session. One that still fails asks the user and re-runs. The router defers only on the user's explicit word ([why](docs/agents/DECISIONS.md#the-run-loop)).
- **What a sub-agent learns stays on its task.** It records a `**Fact:**` or `**Root cause:**` line, and the long form goes in `state/facts/<id>.md`. There is no shared note file and no cross-task memory.
- **`radin-batch` worktree and branch answers never reach a prompt.** Only `radin-state.sh prepare` turns them into git commands. A model that receives them can eventually override a `no`.
- **`radin wire` snapshots before the upstream write.** The upstream installer replaces the whole hook array and does not merge ([limits](docs/agents/DECISIONS.md#limits-of-the-codebase-memory-mcp-bracket)).
- **One C file only: the TUI (`lib/radin-tui.c`).**
  - The TUI draws and dispatches keys with raw ANSI and `termios`. Every mutation shells out to `radin-backlog.sh`.
  - `install.sh` builds it with `cc`, and the build is advisory. Without a compiler there is no TUI ([rules](docs/agents/DECISIONS.md#the-human-tui)).
- **`order` moves a dependency up, never a dependent down.** Kahn's algorithm with a priority tie-break discards more of the human ranking.
- **The TUI loads `backlog list --order created`,** so a mutation reorders nothing. `Shift-A`, `Shift-P`, `Shift-C`, and `Shift-T` are the only reorder keys. They last one session, and the header shows the active one. The CLI default stays `priority`, the contract `radin-prioritization.md` reads.
- **One sub-agent takes one task** and returns one `STATUS` line. A leaf starts cold, so batching tasks for file locality saves no tokens.
- **Plan one task at a time, just in time.** Only a wave of ready tasks is planned together, because nothing lands between those plans and their execution; a later wave drifts when an earlier commit changes the tree ([why](docs/agents/DECISIONS.md#the-run-loop)).
- **No arena or judge at execution level.** N worktrees and a judge that reads N diffs break the router's low-resolution rule. At planning it stays an opt-in in its own backlog entry, gated on a review-origin rollup.
- **No model escalation on retry.** All four roles (planning, execution, review, debug) default to sonnet.

## Before committing

- `make lint`, `make check` and `make test` come back clean.
  - While iterating, run `make test-changed` or `make test T="tests/state-1.bats"`. The full `make test` stays the gate before a commit and in CI.
  - Every tree-only test replays one recorded `install.sh` run. A live run serves only install-time behavior.
  - The mock command is `tests/helpers/mock.c`, one compiled binary, because `/bin/sh` startup costs 20 ms per stub call.
  - No test makes a network request.
- Optional: `make verify-hosts` runs the real opencode and codex CLIs. It needs a C compiler and, with `VERIFY_ARGS=--install-missing`, npm.
- Update the docs in the same commit: `docs/agents/DECISIONS.md` (a new constraint or decision, as one rule plus its `**Why:**`), `docs/agents/lifecycle/*.mmd` (a changed skill flow, run-loop phase, leaf step or task status), the README (a new skill or companion).

## Test coverage

- A feature is stable only when tests verify every path it adds or changes: install, update, doctor, uninstall, the `radin` dispatcher, the TUI, and each host's render.
- Run the feature end to end and compare the result with its stated behavior before you call it complete.
- Reject a test that passes only when everything goes right, pins formatting or escape bytes, or repeats another test's case. Delete a test that another test or a `make check` lint already covers.

## Testing strategy

Test cost is process spawns. A spawn is a wall-clock wait of 10 to 30 ms on macOS, not CPU, so the suite counts forks, not lines. Measure a change against the full `make test` wall time, which was 2m43s before the spawn work and 2m26s after, both at the default JOBS (one per core, 8 here). The slowest files (install-2, install-4, opencode-companions) set the floor at about 90 s.

- **Pick the cheapest tier that can fail.**
  1. Pure logic: call the script or the `render-host.sh` function once on a fixture file.
  2. Installed tree: `replay_install` copies the one recorded `install.sh` run. `make test` records it once (`tests/helpers/build-template.sh`) and exports `RADIN_TEMPLATE`. A lone `bats` run records its own in `setup_file`.
  3. Live `install.sh` (`real_install`, `install_from`): only when the subject is install-time behavior, such as a missing binary, a pre-existing file or a second run. Each run costs 2 to 3 s.
- **Build shared state once per file.** A repo, a backlog or a seed tree goes in `setup_file`, and `setup` copies it with `cp -a`. Never rebuild it per test with `git init`, a commit and a `backlog add`.
- **Reuse the compiled mock.** `tests/helpers/mock` comes from `make build`. A test never compiles `mock.c` into its own temp directory.
- **Spawn once, not per file.** `install.sh` renders every file of a host in one `render-host.sh --batch` run and rewrites tokens with one `sed`. Add a loop around an external command only when you have measured that it stays small.
- **One owner per behavior.** Before you add a test, grep `tests/` for the behavior. Extend the owning test with an assertion instead of adding a second install.
- **Parallelism.** `make test` runs one bats process per file, `JOBS` at a time (default one per core). Keep every file under about 30 s so no file is the tail. Split a longer file into shards.
- **Profile before you optimize.** Run `bats --timing tests/<file>.bats` alone. Times from a full run include contention and mislead.
- **Dev loop.** `make test-changed` runs the files that cover your uncommitted changes (`scripts/affected-tests.sh`). `make test T="tests/a.bats tests/b.bats"` runs the files you name. `make golden` rewrites the golden sums through one file.

See [decisions](docs/agents/DECISIONS.md) · [lifecycle diagrams](docs/agents/lifecycle.md) · [contributing](CONTRIBUTING.md).
