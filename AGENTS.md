# radin Agent Reference

radin is a Claude Code plugin of skills, a CLI, and install glue.

## Hard rules

- **bash 3.2** (macOS ships it). Use no associative arrays, `mapfile`, or `${var,,}`. Add no `uname` branch. Resolve tools with `command -v` or `brew shellenv`. Branch only where a tool differs (`md5` versus `md5sum`). Call out every script edit.
- **`~/.claude` is not ours.** `~/.radin` is. `install.sh` writes `.sh`, `.c` and `.txt` only under `~/.radin/lib` and `.md` only under `~/.radin/hosts/<host>/lib`. It runs `cp` only on radin's own named files, plus `mkdir -p`. It never runs `rm`, deletes with a wildcard, or overwrites a file radin does not ship. Nine exceptions:
  1. The `<!-- radin:begin -->`…`<!-- radin:end -->` block in `~/.claude/CLAUDE.md`.
  2. The `lib/radin-cbm-config.sh` snapshot (kept in `~/.radin/backups`) and restore of `settings.json` and `~/.claude.json`.
  3. `skills/unslop/SKILL.md` and `skills/technical-writing/SKILL.md`. `install.sh` fetches both from upstream and overwrites them only when `manifest.json` lists them as radin's own.
  4. `skills/radin-execute`, `skills/radin-implement` and `skills/radin-run`, renamed to `radin-batch` and `radin-do`. `install.sh` removes one only when its `SKILL.md` still has radin's own `name:` line.
  5. `skills/thermo-nuclear`. `install.sh` removes it only when the fresh `thermo-nuclear-code-quality-review` copy is ready. `tests/bash-compat.bats` pins that one `rm`.
  6. `.ponytail-band`. `install.sh` writes `off` only when the file is absent, so ponytail's band starts hidden.
  7. Two `Read(//…/.radin/**)` strings in `permissions.allow` of `settings.json`. `radin-cbm-config.sh allow` adds them and `unallow` removes exactly those strings and the two legacy `Read(//…/.claude/.radin/**)` ones. `unallow-legacy` removes the legacy pair alone, after a migration. No other key or rule changes ([why](docs/DECISIONS.md#platform-and-install)).
  8. `~/.claude/.radin`. `install.sh` moves it once to `~/.radin` with `mv`, only when it holds a radin manifest, through `~/.radin.migrating`. A foreign `~/.radin` or a leftover staging directory aborts before any write ([why](docs/DECISIONS.md#platform-and-install)).
  9. `--force` moves an unowned or edited radin-named path to `~/.radin/backups` with `mv`, then installs radin's file. It runs no `rm` there. Without `--force` that path stops its host or stays as the user left it ([why](docs/DECISIONS.md#platform-and-install)).

  Call out every `install.sh` edit.
- **Companion install is advisory.** A failed install prints a warning and the run continues. The installer asks one question: which package manager installs the companions (`brew`, `mise`, or `curl`). radin adds no package manager the user has not already run.
- **Tests never touch the real device setup.** No test reads or writes the real `~/.claude`, `~/.config/.claude`, `~/.claude.json`, the `CLAUDE_CONFIG_DIR` target or the keychain. Tests use mocks and stubs under an isolated `HOME`.

## Rule enforcers

| Rule | Enforcer | Gap |
| --- | --- | --- |
| bash 3.2 | `tests/bash-compat.bats` | Grep only; no 3.2 interpreter run. |
| `~/.claude` ownership | `tests/cbm-config.bats` (`allow` keeps foreign rules, follows a symlink, `unallow` removes only radin's), `tests/install.bats` ("never overwrites a skill radin did not install"), `tests/bash-compat.bats` (`rm` allowlist), `SHIPPED` (install copies and uninstall removes only listed names) | Foreign content in the `CLAUDE.md` block and settings restore is untested. |
| Migration of `~/.claude/.radin` aborts before any write | `tests/install.bats` (foreign `~/.radin`, failed `mv`, leftover staging directory, half-migrated, symlinked `~/.claude`, old updater) | An interrupted copy on a real second device is untested. |
| Rendered `.md` only under `~/.radin/hosts/<host>/lib` | `tests/install.bats` layout test, `scripts/shipped.sh check` (`lib` versus `hostlib` kinds) | None. |
| One list of shipped files | `scripts/shipped.sh check`, run by `make check` | README row text is hand-written. |
| Install changes only paths radin owns | `tests/install.bats` (the unowned, edited and `--force` tests) | A foreign file inside a radin skill directory is overlaid, not checked. |
| A forbid hit stops one host | `tests/install.bats` (the claude and agents render-failure tests) | None. |
| Companion install is advisory | `tests/install.bats` ("a failing companion tool...") | None. |
| One owner per delegation | `tests/skill-names.bats` (every name resolves) | Nothing for "one file per delegation" and graph tool names; review only. |
| One owner per prose rule | `LEAF_CONTRACT`, `EXPLORE_RULE`, `OPEN_DECISIONS_RULE` and `PLANNING_RULE` tokens, `scripts/check-prose.sh` (new verbatim sentence copy) | A paraphrase or contradiction; review only. |
| Name each companion directly, no guard or escape clause | `scripts/check-prose.sh` guard phrases | A paraphrase escapes the phrase list. |
| A test must be able to fail | `scripts/check-prose.sh` bare `! cmd` lint | Other vacuous patterns; review only. |
| Tests never touch the real device setup | `make test` runs bats with `CLAUDE_CONFIG_DIR` unset and fails when `scripts/real-setup-sum.sh` differs before and after | A test that reads the keychain or another real path; review only. |
| `--dry-run` changes nothing | `tests/install.bats` ("--dry-run lists the writes the real run makes and changes nothing") | Companion command text is printed, not run. |
| A selected host with no CLI still installs | `tests/install.bats` ("a selected host without its CLI warns...") | None. |
| Same checks locally and in CI | `make check` and `make test` in `.github/workflows/ci.yml` | Linux run unverified. |
| Deterministic work lives in the CLI | `scripts/check-prose.sh` raw `git` lint over `lib/radin-run.md` and `lib/radin-batch-*.md` | Other deterministic steps in prose, and a raw `git` outside those files; review only. |
| No namespaced companion name outside the table | `scripts/check-prose.sh` sixth lint (`.sh` literals, tokens missing from a table) and `tests/skill-names.bats` | A bare name written without a slash; review only. |
| Host-specific text lives in host blocks | `scripts/render-host.sh` (marker errors, surviving forbidden string) and the `scripts/check-prose.sh` forbid lint with `hosts/forbid-baseline.txt` | A Claude-only idea worded with no forbidden string; review only. |
| Lifecycle diagrams match the skills and the run loop | None; `make diagrams` regenerates the SVGs | Review only. |
| Claude render unchanged | `tests/install.bats` golden render test, `make golden` | Files outside `SKILL.md` and `lib/*.md` are unhashed. |

Add a row with every new hard rule.

## Where to edit what

| Change | Edit |
| --- | --- |
| A host difference in a skill or lib file | A `<!-- host:NAME -->` block in the source. A forbidden string goes in `hosts/forbid-<host>.txt`. A companion skill name is `@@skill:NAME@@` in prose and `radin_skill NAME` in a script, spelled by `lib/skill-names-<host>.txt`. |
| A skill's behavior | `skills/<name>/SKILL.md`, never the installed copy. |
| Anything deterministic (install, update, doctor, uninstall, backlog, state, TUI) | A `bin/radin` subcommand in `lib/`, never a skill. |
| Backlog loop of `radin-batch` and `radin-do` | `lib/radin-run.md`. |
| Rare-need part of `radin-batch` | `lib/radin-batch-*.md`, read on demand. |
| A constraint, a decision, or a rule with its reason | `docs/DECISIONS.md`, one bullet: the rule, then `**Why:**`. No layout, verb list or format table: the code and the graph hold those. |
| A skill's flow, a `radin-run.md` phase, a leaf step, or a task status | `docs/lifecycle/*.mmd`, then `make diagrams` ([diagrams](docs/lifecycle.md)). Commit the `.mmd` and `.svg` together. |
| The README screenshot | `make screenshot`, then commit `docs/img/tui.svg`. |
| What ships, a renamed or removed skill or lib file | `SHIPPED`, then `make gen` ([how](docs/DECISIONS.md#platform-and-install)). |
| Sub-agent model, CLI invocation | Nothing. Write a token and `install.sh` resolves it ([how](docs/DECISIONS.md#platform-and-install)). |

A new skill also needs a README row. `make check` names any step you missed.

A new companion that ships stats or a gain command needs a bullet in `skills/radin-stats/SKILL.md`.

## Storage

The state directory is `<repo-root>/.claude/.radin/`, under `$PWD`. It holds `backlog/` (`index.jsonl` and `tasks/<id>.md`), `state/`, `plans/`, and `reviews/` ([rules](docs/DECISIONS.md#state-and-data)). It is the only thing radin writes into a consumer repo. radin never touches that repo's `.gitignore`.

Read and write it only through the CLI (`radin backlog …`, `radin state …`). No code parses `index.jsonl` or `completed.json`, or grabs a task by line number. When no subcommand gives the view you need, add one.

## Skills, agents, sub-agents

Every entry point is a skill, because only a skill runs in the user's thread and can talk to the user. A sub-agent is a leaf worker that a skill dispatches. It cannot write prose to the user, call `AskUserQuestion`, or receive a background-task notification.

- Before a prompt points at a skill, check that the skill asks the user nothing and spawns no agent ([constraints](docs/DECISIONS.md#skills-and-sub-agents)).
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
- **Name another skill. Never restate it** ([one rule, one file](docs/DECISIONS.md#one-rule-one-file)).
- **Use the short, exact word,** one term per concept. Keep "the", "a", "not", "only". Skip em dashes, colon connectors, metaphor nouns, and "simply".
- **A cut never adds words.** Compare `wc -w` before and after. When no sentence fails the no-op test, leave the file unchanged.

More rules: `/mattpocock-skills:writing-for-agents`, the `STE` output style, `unslop` (human-facing prose), `technical-writing` (docs, READMEs, PR and commit text).

## Delegation: one owner per job

When a shipped tool does a job, name that tool. Never write a radin version. Name each delegation in one file ([a test pins every name](docs/DECISIONS.md#skills-and-sub-agents)).

| Job | Owner |
| --- | --- |
| Settle a decision · API facts · module boundaries · diagnose a failure | `/mattpocock-skills:grilling` · `:research` · `:codebase-design` · `:diagnosing-bugs` |
| Minimal change · over-engineering · debt ledger | `/ponytail:ponytail` · `-review`/`-audit` · `-debt` |
| Maintainability review · commit message | `/thermo-nuclear` · `/caveman:caveman-commit` |
| Implementation discipline | `/caveman:surgical-patch` (fix), `safe-refactor`, `lean-build` (feat) |
| Code structure questions | codebase-memory-mcp's MCP tools |
| Output compression | `rtk` |
| Agent-doc writing rules | `/mattpocock-skills:writing-for-agents` |

The graph tool name lives in one file and must exist in the upstream table ([which files, and the pointer rule](docs/DECISIONS.md#limits-of-the-codebase-memory-mcp-bracket)).

## Decisions that look like bugs

- **No router-side per-task verification in `radin-batch`.** The leaf verifies and reviews its own staged diff before it commits. A `FAILED` task gets a Debug prompt once per session. One that still fails asks the user and re-runs. The router defers only on the user's explicit word ([why](docs/DECISIONS.md#the-run-loop)).
- **What a sub-agent learns stays on its task.** It records a `**Fact:**` or `**Root cause:**` line, and the long form goes in `state/facts/<id>.md`. There is no shared note file and no cross-task memory.
- **`radin-batch` worktree and branch answers never reach a prompt.** Only `radin-state.sh prepare` turns them into git commands. A model that receives them can eventually override a `no`.
- **`lib/radin-cbm-config.sh` snapshots before the upstream write.** The upstream installer replaces the whole hook array and does not merge ([limits](docs/DECISIONS.md#limits-of-the-codebase-memory-mcp-bracket)).
- **Two C files only: the TUI (`lib/radin-tui.c`) and the JSON helper (`lib/radin-cbm-json.c`).**
  - The TUI draws and dispatches keys with raw ANSI and `termios`. Every mutation shells out to `radin-backlog.sh`.
  - The helper holds every JSON rule that `radin repair` and `radin hooks mcp` need. Those scripts keep none. radin needs no Python.
  - `install.sh` builds both with `cc`, and the build is advisory. Without a compiler there is no TUI and no `radin repair`, and `radin hooks mcp` prints an entry to paste by hand ([rules](docs/DECISIONS.md#the-human-tui)).
- **`order` moves a dependency up, never a dependent down.** Kahn's algorithm with a priority tie-break discards more of the human ranking.
- **The TUI loads `backlog list --order created`,** so a mutation reorders nothing. `Shift-A`, `Shift-P`, `Shift-C`, and `Shift-T` are the only reorder keys. They last one session, and the header shows the active one. The CLI default stays `priority`, the contract `radin-prioritization.md` reads.
- **One sub-agent takes one task** and returns one `STATUS` line. A leaf starts cold, so batching tasks for file locality saves no tokens.
- **Plan one task at a time, just in time.** A wave plan of every task drifts when an earlier commit changes the tree ([why](docs/DECISIONS.md#the-run-loop)).
- **No arena or judge at execution level.** N worktrees and a judge that reads N diffs break the router's low-resolution rule. At planning it stays an opt-in in its own backlog entry, gated on a review-origin rollup.
- **No model escalation on retry.** All four roles (planning, execution, review, debug) default to sonnet.

## Before committing

- `make lint`, `make check` and `make test` come back clean.
  - Every tree-only test replays one recorded `install.sh` run. A live run serves only install-time behavior.
  - The mock command is `tests/helpers/mock.c`, one compiled binary, because `/bin/sh` startup costs 20 ms per stub call.
  - No test makes a network request.
- Update the docs in the same commit: `docs/DECISIONS.md` (a new constraint or decision, as one rule plus its `**Why:**`), `docs/lifecycle/*.mmd` (a changed skill flow, run-loop phase, leaf step or task status), the README (a new skill or companion).

## Test coverage

- A feature is stable only when tests verify every path it adds or changes: install, update, doctor, uninstall, the `radin` dispatcher, the TUI, and each host's render.
- Run the feature end to end and compare the result with its stated behavior before you call it complete.
- Reject a test that passes only when everything goes right, pins formatting or escape bytes, or repeats another test's case.

See [decisions](docs/DECISIONS.md) · [lifecycle diagrams](docs/lifecycle.md) · [contributing](CONTRIBUTING.md).
