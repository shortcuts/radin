# Rule enforcers

One row per hard rule in [AGENTS.md](../../AGENTS.md). Add a row with every new hard rule.

| Rule | Enforcer | Gap |
| --- | --- | --- |
| Agents-host `SKILL.md` follows the Agent Skills spec | `tests/lints.rs` (`agents_render_of_every_skill_follows_the_agent_skills_spec`: fields, name, description length, body lines) | The spec's `skills-ref validate` is not run. |
| Rust style and lint | `make lint` and `make check` (`cargo fmt --check`, `cargo clippy --all-targets -- -D warnings`, `shellcheck` and `shfmt` on `install.sh`) | Review only for a runtime OS branch (no `uname`). |
| `~/.claude` ownership | `tests/cbm_config.rs` and `src/cbm/config.rs` (`allow` keeps foreign rules, follows a symlink, `unallow` removes only radin's), `tests/install_*.rs` ("never overwrites a skill radin did not install", the agents companion skill cases), `SHIPPED` (install copies and uninstall removes only listed names) | Foreign content in the `CLAUDE.md` block and settings restore is untested. |
| Migration of `~/.claude/.radin` aborts before any write | `tests/install_*.rs` (foreign `~/.radin`, failed `mv`, leftover staging directory, half-migrated, symlinked `~/.claude`, old updater) | An interrupted copy on a real second device is untested. |
| Rendered `.md` only under `~/.radin/hosts/<host>/lib` | `tests/install_*.rs` layout test, `tests/shipped.rs` (`lib` versus `hostlib` kinds) | None. |
| One list of shipped files | `tests/shipped.rs`, run by `make check` | README row text is hand-written. |
| The `fff` server entry is added only when absent and removed only when radin added it | `tests/install_companions.rs` (the claude fff test, the codex and opencode companion tests), `src/jsonedit.rs` (`opencode_mcp` keeps a foreign entry) | Codex `mcp get` exit codes run against a stub. |
| Install changes only paths radin owns | `tests/install_*.rs` (the unowned, edited and `--force` tests) | A foreign file inside a radin skill directory is overlaid, not checked. |
| A forbid hit stops one host | `tests/install_*.rs` (the claude and agents render-failure tests) | None. |
| Companion install is advisory | `tests/install_*.rs` ("a failing companion tool...") | None. |
| The overlap judge runs on the execution model | `tests/prompt.rs` (`prompt_judge_renders_evidence_and_the_execution_model`) | The host's model for that token; review only. |
| One owner per delegation | `tests/lints.rs` (every name resolves) | Nothing for "one file per delegation" and graph tool names; review only. |
| One owner per prose rule | `LEAF_CONTRACT`, `EXPLORE_RULE`, `OPEN_DECISIONS_RULE` and `PLANNING_RULE` tokens, `tests/lints.rs` (new verbatim sentence copy) | A paraphrase or contradiction; review only. |
| Name each companion directly, no guard or escape clause | `tests/lints.rs` guard phrases | A paraphrase escapes the phrase list. |
| A test must be able to fail | `tests/lints.rs` bare `! cmd` lint | Other vacuous patterns; review only. |
| Tests never touch the real device setup | `make test` runs `cargo test` with `CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `XDG_CONFIG_HOME` and `OPENCODE_CONFIG` unset and fails when `make real-setup-sum` differs before and after; `tests/common/mod.rs` `isolate` points every host path under a temp `HOME` | A test that reads the keychain or another real path; review only. |
| `RADIN_HOST` selects skill names, never a state dir | `src/host.rs` unit tests | None. |
| Legacy `.claude/.radin` and `.agents/.radin` migrate into `.radin` without loss | `tests/migrate.rs` | A crash between the copy and the rename is untested. |
| `.gitignore` gets `.radin/` once | `tests/migrate.rs` | None. |
| `radin doctor` checks every installed host | `tests/doctor.rs` | The real CLI probes (Codex `/hooks`, opencode version) run against stubs. |
| `radin uninstall` removes only bytes radin still owns | `tests/uninstall.rs`, the three-host lifecycle test in `tests/install_*.rs` | Foreign text inside a radin block is stripped with it. |
| The agents render names no Claude-only tool and holds no model line | `lib/forbid-agents.txt`, `tests/lints.rs` forbid lint, `src/render.rs` unit tests | A paraphrase of a tool name; review only. |
| Every host path variable is isolated | `tests/isolation.rs` (both tests) | None. |
| A three-host lifecycle leaves no radin file | The three-host lifecycle test in `tests/install_*.rs` | The real CLIs are not run; `make verify-hosts` owns that. |
| Real CLIs load radin's files | `make verify-hosts` (opt-in) and `tests/verify_hosts.rs` (`a_complete_tree_passes_both_hosts` runs against stubs in `make test`) | Linux and opencode 1.x unverified; opencode skills are a file check only. |
| `--dry-run` changes nothing | `tests/install_*.rs` ("--dry-run lists the writes the real run makes and changes nothing") | Companion command text is printed, not run. |
| Install asks every question before the first write | `tests/install_*.rs` wizard cases (forward, back, checkbox, `--update` Recap, `--yes` and `STEP_TOTAL`) | A terminal that rejects raw mode falls back to numbered prompts with no back; review only. |
| A selected host with no CLI still installs | `tests/install_*.rs` ("every selected host installs its files when no host CLI exists") | None. |
| `radin update` keeps a failed host in the manifest | `tests/install_*.rs` ("--update leaves a host whose render fails untouched...") | None. |
| An overlap graph gap exits 2, skips the symbol tier and records a `setup-issue` telemetry line | `tests/overlap.rs` (`every_graph_gap_exits_2_and_records_telemetry`) | The real graph CLI runs against a stub; its JSON shape is measured on 0.12.1 only. |
| Lane mode is derived once per run; `main` mode makes no worktree and no branch | `tests/state_lanes.rs` | The router's overlap clearance is the run-loop task. |
| A lane merges only through the queue, with `--no-ff`, one at a time | `tests/state_lanes.rs` queue and merge tests, `tests/prompt.rs` (`prompt_sync_lane_renders_the_epic_dir_and_answer`) | The router's loop over `lane-merge` is a separate task. |
| A merged lane passes the gate before `lane-done`; a red main files a fix entry and never reverts | `tests/state_lanes.rs` (`lane_gate_*`, `two_failed_gates_*`, `an_open_hotfix_*`, `a_hotfix_lane_that_fails_twice_*`), `tests/prompt.rs` (`prompt_gate_lane_renders_*`) | The router's loop over `lane-gate` is prose; review only. |
| A dead lane session is recovered in Phase 0 without landing unverified work | `tests/state_lanes.rs` (`lanes_recover_*`, `recover_parks_a_lane_task_*`, `prepare_resumes_a_parked_task_in_main_mode`) | A crash in the root checkout mid-merge is untested. |
| Legacy task state is gone: `reconcile` lands a legacy branch without markers and `steps-init` clears them | `tests/state_1.rs`, `tests/state_2.rs` | A crash between the squash and the record is untested. |
| A parked lane task keeps its work on `radin/wip/<id>` | `tests/state_lanes.rs` park tests | A crash between the branch and the reset, and the `claim` MAX_ATTEMPTS path, are untested. |
| A task commit cannot quietly edit the files that judge it | `tests/state_1.rs` (`task_report_journals_a_verification_file_edit_*`, `a_verification_file_the_plan_lists_*`), `src/state/plan_cover.rs` unit test | The path list is fixed, not per repo; a repo-specific check file is unlisted. |
| A high-risk lane gets a fresh-context review | `tests/state_lanes.rs` (`a_lane_map_prints_risk_high_*`), `tests/prompt.rs` (`prompt_gate_lane_reviews_only_a_high_risk_lane`) | The leaf's own `Risk:` value feeds the trailer; a wrong rating is review only. |
| A repeated finding pattern becomes a `REVIEW.md` rule | `tests/state_1.rs` (`pattern_seen_counts_per_slug_*`) | The gate leaf's append and commit is prose; review only. |
| Context a host loads stays under a ceiling | `radin context --check` in `make check` (`ALWAYS_CEILING` and `ROUTE_CEILING` in `src/context.rs`), `tests/context.rs` | The 4-bytes-a-token estimate is rough; `radin stats` shows the measured load. A new `RADIN_LIB/` reference in a lib file raises a route, so a ceiling bump needs a reason in the commit. |
| Same checks locally and in CI | `make check` and `make test` in `.github/workflows/ci.yml` | Linux run unverified. |
| Deterministic work lives in the CLI | `tests/lints.rs` raw `git` lint over `lib/radin-run.md` and `lib/radin-batch-*.md` | Other deterministic steps in prose, and a raw `git` outside those files; review only. |
| No namespaced companion name outside the table | `tests/lints.rs` name lint (`.sh` literals, tokens missing from a table) and its skill-name tests | A bare name written without a slash; review only. |
| Host-specific text lives in host blocks | `src/render.rs` (marker errors, surviving forbidden string) and the `tests/lints.rs` forbid lint with `hosts/forbid-baseline.txt` | A Claude-only idea worded with no forbidden string; review only. |
| Lifecycle diagrams match the skills and the run loop | None; `make diagrams` regenerates the SVGs | Review only. |
| Claude render unchanged | `tests/golden_render.rs` and `tests/install_core.rs`, `make golden` | Files outside `SKILL.md` and `lib/*.md` are unhashed. |
