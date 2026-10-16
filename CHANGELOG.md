# Changelog

## [2.0.0](https://github.com/shortcuts/radin/compare/v1.0.1...v2.0.0) (2026-10-16)


### ⚠ BREAKING CHANGES

* **install:** `install.sh --force` and `make install-force` are gone; a plain install upgrades every companion. `radin update` runs no companion installer and asks the model question again.
* **state:** one CLI call per task, namespace from cwd
* **state:** `task-done` and `triage` read the recorded branch instead of deriving `radin/<id>`, so a task prepared by an older session reports an unknown branch. Nothing backfills the four new fields.
* **backlog:** an existing backlog is not migrated. Re-state each task's criteria, plan pointers and skills with `set-meta`/`add-plan`, then delete those labels from the body.
* **backlog:** own the execution order in the CLI
* **state:** steps entries carry a debugged flag and a fifth `deferred` status, steps-init takes a fourth stdin field, completed.json carries a title, task-done exits 3 on a hash that is not reachable from the task's branch, and lib/radin-execute-dirty.md is deleted -- it was one CLI call.
* **tui:** enter no longer opens $EDITOR on a task row -- e does, and always did.
* **tui:** the row is no longer coloured; the priority cell is.
* **tui:** `n` no longer creates a task; `a` does. `/` no longer hides non-matching rows -- every row stays visible and a `*` in the left margin marks a match.

### Features

* **backlog:** add files verb printing plan Changes paths ([7d200a1](https://github.com/shortcuts/radin/commit/7d200a132508441d5a83e4db496a190032d9ed5d))
* **backlog:** group tasks under epic directories ([6daf023](https://github.com/shortcuts/radin/commit/6daf0238a0885125f3f2c396670db70b5bfa8c96))
* **backlog:** own the execution order in the CLI ([8e78461](https://github.com/shortcuts/radin/commit/8e78461338d06597061d74b704aceaa71c132141))
* **backlog:** parse an **Acceptance:** checklist out of a task body ([26c66a8](https://github.com/shortcuts/radin/commit/26c66a8e84b9ea0ffb18c3fc7abeb9e3034a4534))
* **backlog:** restrict priority to a Fibonacci scale ([f99168b](https://github.com/shortcuts/radin/commit/f99168b09c4b20d238336400ae51d2085c740712))
* **backlog:** store priority and depends_on on the index line ([0615572](https://github.com/shortcuts/radin/commit/0615572350bd557e0ad39f23f12df6f645ec50e9))
* **cli:** add scope --commits, wire, plan-target slugs ([b5aef4f](https://github.com/shortcuts/radin/commit/b5aef4f50dcc1b30f638e08baf929539c79e8060))
* **cli:** open the TUI on bare radin, add radin help ([a6036ca](https://github.com/shortcuts/radin/commit/a6036cabbaed79a9a852f5c835956866c968aec9))
* decide at record time whether a task needs a plan ([55c3bae](https://github.com/shortcuts/radin/commit/55c3bae3615ed423cf4d3da347d9854d886e41df))
* **execute:** add STATUS: INCONCLUSIVE verdict for unverifiable changes ([e887e69](https://github.com/shortcuts/radin/commit/e887e69dd2a3d109e611326ddbf339f9e474b838))
* **execute:** ask per session whether the full suite runs per task or at the end ([7fbf2ee](https://github.com/shortcuts/radin/commit/7fbf2ee0043f8480bccf1b74b83f4f6d01589b00))
* **execute:** ask the user on failed or blocked tasks and re-run, never defer ([9ea3575](https://github.com/shortcuts/radin/commit/9ea35755f314f17d0576a6a0f418ccc17300d300))
* **execute:** drop test mode, leaf verifies its own work ([b387b13](https://github.com/shortcuts/radin/commit/b387b13ee54b331ab9fdcb53c2016a0692dcd0d2))
* **execute:** review the staged diff before each task commits ([d78dbb2](https://github.com/shortcuts/radin/commit/d78dbb276b1351ea185e0ac38f66ad31d509fe61))
* **execute:** run full suite once per session on a shared branch ([5daa859](https://github.com/shortcuts/radin/commit/5daa8594c4585cb6ca02b8621f323c25c6fbd928))
* **install:** fetch unslop and technical-writing from cursor/plugins main ([ef7fbd2](https://github.com/shortcuts/radin/commit/ef7fbd26b969747e7e9ce4a6861ea8031c11578a))
* **install:** run chore tasks on their own model role ([cbf4c22](https://github.com/shortcuts/radin/commit/cbf4c2289cf5f23ce0503a602b0f58b77f65209d))
* **install:** split install and update paths ([6563635](https://github.com/shortcuts/radin/commit/6563635f902501376a81d106bd35a35c4c165b2a))
* make record read from atlassian ([b89d8c2](https://github.com/shortcuts/radin/commit/b89d8c2a4d448dc7bb938e1579f32f02f8909fa3))
* one review core for plan, diff and session; evidence-checked plans ([5ee7c80](https://github.com/shortcuts/radin/commit/5ee7c80deb11337ee7fc1ed79a8e72204d917aa3))
* **plan:** add Modes and states section to plan template ([7d9c975](https://github.com/shortcuts/radin/commit/7d9c975f882c12145e2ec68ff57340c5886df30e))
* **plan:** add Reach and reuse section to plan template ([103a335](https://github.com/shortcuts/radin/commit/103a3354c6837ab1e615b0bb8f47db08d28dd725))
* **plan:** add Rubrics triggered section to plan template ([e604d5a](https://github.com/shortcuts/radin/commit/e604d5a9dc06085d2fbcba96c7c2b54bf0ab0620))
* **prioritization:** obey human-set priority and depends_on ([bb20265](https://github.com/shortcuts/radin/commit/bb202652e1959946bb4f47324126ee195bb9b8ca))
* **prompt:** demand test evidence, plan-deviation rule, reuse ponytail hook ([6b16657](https://github.com/shortcuts/radin/commit/6b16657216ddd33c31d516830639094706940116))
* **prompt:** leaf sub-agents end with only the STATUS: line ([07ff1d8](https://github.com/shortcuts/radin/commit/07ff1d83be4643fbd3e3075d29430679029ba7aa))
* **prompt:** name sibling sites in diagnoses, cap leaf reports ([82726e1](https://github.com/shortcuts/radin/commit/82726e1b4180eadb4cb605c51bbe4c4481c55db3))
* **prompt:** warn execution prompts when a plan's files changed since add-plan ([2e372e9](https://github.com/shortcuts/radin/commit/2e372e9e938828641ea99d2d896f14223f9330ca))
* properly leverage cbm tools ([681bb1b](https://github.com/shortcuts/radin/commit/681bb1b5130d2fbde34293ddee5ae6489490441d))
* **radin-execute:** plan every confirmed task in one wave ([67880fc](https://github.com/shortcuts/radin/commit/67880fcfe888ffc85f299204d57f36de3f44ae97))
* report what each task built, chose and left open ([96ff7ef](https://github.com/shortcuts/radin/commit/96ff7efe9df5f211ed4b343b9ab4aa07b516ffea))
* **review:** severity, evidence rung and caller trace per finding ([f2b846d](https://github.com/shortcuts/radin/commit/f2b846d39bfa6add6c06805e2092042ce38a33db))
* **review:** sort triage into Act on, Consider, Noted, Dismissed ([c9b83fd](https://github.com/shortcuts/radin/commit/c9b83fd7cf8944a48b1cd91f6d9dff40808d71bb))
* **review:** tag findings with origin, journal them, roll up in report ([f63e6c9](https://github.com/shortcuts/radin/commit/f63e6c9639c7ebec653cbc3d7ba76d8c23e08679))
* **run:** add /radin-run skill, record one prompt then execute that task ([656b788](https://github.com/shortcuts/radin/commit/656b788bd9a69b3d51e01112d68cdfe3dea61ffd))
* **run:** scope execute and implement to a named epic or task ([a14fd98](https://github.com/shortcuts/radin/commit/a14fd98559a76fb257b5c0d64e99563c104fad6e))
* **scope:** add --attribute mapping cited lines to task and plan ([7192118](https://github.com/shortcuts/radin/commit/7192118d668a5522850090d1df37ac6f9334abf0))
* **scope:** add --tasks, the completed ids a scope covers ([bf92aae](https://github.com/shortcuts/radin/commit/bf92aae2e3bc74e19ce663d0c04c91175e971866))
* **skills:** add radin-implement, radin-execute without the planning pass ([ceebc4f](https://github.com/shortcuts/radin/commit/ceebc4fb426eee81e0a45eb0c0fc988a6e3879a9))
* **skills:** end every skill with a Reply line, label Fact and Root cause lines ([12befae](https://github.com/shortcuts/radin/commit/12befaeb1881f15c12fb163e81e504ec04c9de42))
* **skills:** grill the user instead of assuming on a broad task ([76c8f5b](https://github.com/shortcuts/radin/commit/76c8f5b65461de640c8f6b401f330ed28d118066))
* **state:** add steps-list for resume triage ([aba9bba](https://github.com/shortcuts/radin/commit/aba9bbad45058e92bd6fadb8df4c478a523010c4))
* **state:** add trace, the provenance lookup in all directions ([69aacf9](https://github.com/shortcuts/radin/commit/69aacf992dcea876351456ded25a51e4633adaf3))
* **state:** halt after three failures in a row, retry infra deaths ([d148afb](https://github.com/shortcuts/radin/commit/d148afb635924a1662b4c453fd9be3ce0e0b336f))
* **state:** name plan sections that recur across review findings ([d21140a](https://github.com/shortcuts/radin/commit/d21140a3ac3f28dd12ab87df3ac39c2f13a68212))
* **state:** one CLI call per task, namespace from cwd ([507463a](https://github.com/shortcuts/radin/commit/507463a976f36f7908ea81c83f37bbed3f8364be))
* **state:** own radin-execute's loop in the CLI ([e8b65fa](https://github.com/shortcuts/radin/commit/e8b65fa9f7207dc334eb0f2798ecae6d3ce26e86))
* **state:** record execution provenance on the completed line ([bc0ff8c](https://github.com/shortcuts/radin/commit/bc0ff8cc1829fd9fe1b383ee09a57a2ad8cb5b6f))
* **state:** report out-of-plan files a task's commit changed ([9c4fcba](https://github.com/shortcuts/radin/commit/9c4fcba4429690c83bbace2b5eda736e5194e151))
* **state:** task-next prints overlap hint for execution tasks ([168923c](https://github.com/shortcuts/radin/commit/168923c3ef4bcb16eaec513c59d45c869f607acb))
* **state:** task-report --next claims next task on continue ([bbfc670](https://github.com/shortcuts/radin/commit/bbfc670d4ee23c1de2805fb15b0c59b8bfbc6559))
* **state:** task-report --usage journals sub-agent usage, report sums per kind ([f1a3a65](https://github.com/shortcuts/radin/commit/f1a3a6525db902a3949bd6688d2d0ee47be33d58))
* **tui:** / is a search, n/N walk matches, a creates ([0bcb617](https://github.com/shortcuts/radin/commit/0bcb617f94fae38e9cf6c912f3634ccaf3b79d40))
* **tui:** 256-colour palette, boxed panes, accent selection ([1e4cd23](https://github.com/shortcuts/radin/commit/1e4cd23edbbf85391d5f177182afe5dd398a0305))
* **tui:** add `radin tui`, a human backlog browser ([2f8b51a](https://github.com/shortcuts/radin/commit/2f8b51a95f855b8a710e4c639e2da2a872bbe5c9))
* **tui:** add epic tree, detail pane and Done view ([bfe772d](https://github.com/shortcuts/radin/commit/bfe772dc48a0489cad88302ec1b92c0d49f8a72a))
* **tui:** add keys to set priority, deps and epic ([4960ab0](https://github.com/shortcuts/radin/commit/4960ab08855a94ee535f72892270c90628720d48))
* **tui:** colour rows by relative priority band ([41a51c7](https://github.com/shortcuts/radin/commit/41a51c7e1e54b4412384ad1a4a499b790a520386))
* **tui:** draw epic children as a tree with box-drawing connectors ([8ad0579](https://github.com/shortcuts/radin/commit/8ad057920ef392cad9af01463fccdd70c6920629))
* **tui:** e edit epic DESCRIPTION.md on epic row ([1193e20](https://github.com/shortcuts/radin/commit/1193e201eeb16b84a348fc4586d4806e7e904f61))
* **tui:** fence the panes, section the detail, widen colour ([c2db12c](https://github.com/shortcuts/radin/commit/c2db12c6f62128470a62ebb39df4a70013840a8b))
* **tui:** list in creation order, Shift keys to sort ([7668e1e](https://github.com/shortcuts/radin/commit/7668e1e2fb5396d231f4d32d6cab6f1e6d50468f))
* **tui:** o pages the execution order ([8a1f14d](https://github.com/shortcuts/radin/commit/8a1f14d8d4605225ea9199b2bc2ffe1ef3875342))
* **tui:** poll index.jsonl every 5s ([c6a07f7](https://github.com/shortcuts/radin/commit/c6a07f793508ca8fe022776c4cc4933aefdedb76))
* **tui:** priority is its own column, coloured absolutely ([9bd5304](https://github.com/shortcuts/radin/commit/9bd5304e6fb4d503d1f4ca9bde5d3db8911a2508))
* **tui:** split the detail into a markdown right pane ([2c927ec](https://github.com/shortcuts/radin/commit/2c927ecbd69225a7e98ed124b23a29ebff6f6d88))
* **tui:** switch the detail pane between task body and plan ([60e4f46](https://github.com/shortcuts/radin/commit/60e4f46c2ba49c7958b0ec7c66562d5c86160071))


### Bug Fixes

* backlog per worktree ([6295e5b](https://github.com/shortcuts/radin/commit/6295e5bcffdc72a025b3a4012071c68b6de48eb2))
* **backlog:** reject tab and newline in titles ([d11a7bc](https://github.com/shortcuts/radin/commit/d11a7bc25f98381cf9b4f5da28a6274c79b0f5f6))
* **cbm-config:** prune dead hooks wrapped in sh, not just a bare path ([186da83](https://github.com/shortcuts/radin/commit/186da833ce9483d89ace6bb702bc1c6b7286b233))
* **cbm-config:** rewrite cbm hook commands to the ~/ form ([f2a6b73](https://github.com/shortcuts/radin/commit/f2a6b73fbd9a3d951a075e96069c0798da978ec9))
* doctor ([3536c10](https://github.com/shortcuts/radin/commit/3536c10421caaef47ab4f09d9499140870ae7785))
* drop intermediate reviews ([a057a68](https://github.com/shortcuts/radin/commit/a057a68c8dcf7849c9fda93cfab7c7920912592e))
* install ([09ce73b](https://github.com/shortcuts/radin/commit/09ce73b0569e7ce747183464020c24535caba2d6))
* install ([019e95f](https://github.com/shortcuts/radin/commit/019e95ff038ce7f6436aad0711169881b9bf2fea))
* install order ([639a538](https://github.com/shortcuts/radin/commit/639a5384cc8f37feb4a363d2e06adbeab75ff07f))
* **install:** enable disabled plugins, make radin-show user-only ([c4f40d7](https://github.com/shortcuts/radin/commit/c4f40d740f7a2d23683bfa9a44407c343913666d))
* **install:** log the cbm-config trace instead of relaying it ([b4f7b44](https://github.com/shortcuts/radin/commit/b4f7b44362526e473cbf4376388467cff11db94b))
* intel install ([b3004e8](https://github.com/shortcuts/radin/commit/b3004e8cc3433f9ac758c1e4c0de5a5907bd7fef))
* make codebase-memory-mcp guidance and hooks reach agents ([ddc1b69](https://github.com/shortcuts/radin/commit/ddc1b69b541b51dc82adb8c37ac8eebae6d271df))
* name ([d977f42](https://github.com/shortcuts/radin/commit/d977f42703443bb1c224a9f3c4dca74f4fba6bdf))
* radin lib path ([17d51f8](https://github.com/shortcuts/radin/commit/17d51f823a272258f88d7584552624933ba7eb8a))
* **radin-plan:** print the six fields find now returns ([980f57b](https://github.com/shortcuts/radin/commit/980f57bdf2a7b573206d45899b089500fdb4315d))
* **radin-record:** set depends_on via set-deps ([e1407d5](https://github.com/shortcuts/radin/commit/e1407d50722bd94168dddeae1e334560eca05ba7))
* **review:** sort backlog entries into spec and decisions without asking ([a86d484](https://github.com/shortcuts/radin/commit/a86d4847e046a4e219d428adc3e11fcd8a76777c))
* **run:** pull a scoped task's dependencies into the scope ([11d5fb1](https://github.com/shortcuts/radin/commit/11d5fb1cfcaf43d959a73acba5464df9ead329c9))
* **state:** stash dirty tree in prepare, align prompts to guides ([da6236b](https://github.com/shortcuts/radin/commit/da6236b8b00524648b56cd166392f506a77f0993))
* tests slow ([7fbed1b](https://github.com/shortcuts/radin/commit/7fbed1bf4ccdb71b3d0ec52eaaf71a697210f798))
* **tests:** run the dispatcher test outside the repo ([e9a3c6b](https://github.com/shortcuts/radin/commit/e9a3c6b1e5469424f81976f7d35467057b24c118))
* tui in c ([de15702](https://github.com/shortcuts/radin/commit/de157020ad5090c38338ec930e4a9b96359750f0))
* **tui:** pad and truncate rows by display column ([490e03a](https://github.com/shortcuts/radin/commit/490e03ad558eeec29717344fb761bf310c2a906d))
* **tui:** wrap detail-pane lines instead of truncating them ([085b47c](https://github.com/shortcuts/radin/commit/085b47c4554fdfe171f78a3f91b0c4f9fad426cc))
* update path ([b2bc59f](https://github.com/shortcuts/radin/commit/b2bc59f4e8b67e8aa38b990a0e125feb8e5a557c))


### Performance Improvements

* **backlog:** one awk pass per read verb instead of a fork per JSON field ([01c6758](https://github.com/shortcuts/radin/commit/01c67584a815087367a308af39918352606ebb8a))
* **execute:** move prompt assembly and post-dispatch bookkeeping to the CLI ([854481d](https://github.com/shortcuts/radin/commit/854481d1bd8485c0ea254030792fbfe42625c20c))
* **mock:** replace gh shell stub with compiled mock ([cf386c3](https://github.com/shortcuts/radin/commit/cf386c371b5cf4d0c2b9db833915cc1de3aa5f40))
* **plan:** skip thermo-nuclear in non-interactive plan review ([d81eb8f](https://github.com/shortcuts/radin/commit/d81eb8f629ec6455c506baa12c8cf83eea5a6e0d))
* **prompt:** inline the task body into the execution prompt ([850b8bd](https://github.com/shortcuts/radin/commit/850b8bd43456cf05572774e14727f93db73b33cf))
* **radin-execute:** drop ponytail ladder from Step 4a triage ([6a8939c](https://github.com/shortcuts/radin/commit/6a8939c43d4ee2d884aff0013336ea5bb6c0768a))
* **radin-execute:** re-run backlog meta only after planner ran ([9f74c6d](https://github.com/shortcuts/radin/commit/9f74c6d6ed305b1aebc6d8b418c0024bec48023b))
* resolve the namespace with one git call ([c4bbf3b](https://github.com/shortcuts/radin/commit/c4bbf3bed604c70fae1c225cf4d27e454654f5ba))
* **skills:** keep user-only skills out of the model listing ([e8687c2](https://github.com/shortcuts/radin/commit/e8687c2e246a82328a403265f483e6aba9c78d2c))
* **tui:** diff frames by row, flush in one sync write ([fa4d211](https://github.com/shortcuts/radin/commit/fa4d211b5fd4f0ac0b0c93271840f4d210d4dabb))
* **tui:** one frame per held-key burst instead of one per keypress ([f942acc](https://github.com/shortcuts/radin/commit/f942accbd13efa9f08cfc3fe8ddd04b58215e9d5))
* **tui:** read meta once per load, cache built detail ([606a1c0](https://github.com/shortcuts/radin/commit/606a1c04bc7c424925a222807c031532664c38c5))


### Code Refactoring

* **backlog:** move the five parsed task labels onto the index line ([13af7f9](https://github.com/shortcuts/radin/commit/13af7f9f020f1d07e107d7fa57e3d0dc88f09fe0))
