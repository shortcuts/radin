<!-- radin:begin -->
## radin

radin keeps a per-repo backlog in `<repo-root>/.radin/` so tasks
survive past one conversation. Reach for it instead of ad-hoc task tracking:

- A bug, idea, or follow-up comes up mid-session: record it with `/radin-record`.
- The user asks what is pending: run `"$HOME/.radin/bin/radin" backlog show` and print its output. One entry needs a plan first: `/radin-plan`.
- The user wants the backlog worked through: `/radin-batch` (it plans the entries `/radin-record` flagged, then executes), or `/radin-do <prompt>` for one ad-hoc task. A code review whose findings should become tasks: `/radin-review`.
- The user asks to mark a task done by hand: run `"$HOME/.radin/bin/radin" state task-done <id> <commit-hash>` (hash from `git rev-parse --short=12 HEAD`). `backlog --help` and `state --help` list every verb.
- Never hand-edit files under `.radin/` -- every backlog operation goes through the `"$HOME/.radin/bin/radin" backlog` CLI.
- Never guess on a broad or ambiguous ask: invoke `/mattpocock-skills:grilling` and let the user settle it before radin writes anything.
<!-- radin:end -->
