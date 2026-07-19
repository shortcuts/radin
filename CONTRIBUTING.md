# Contributing to radin

## Proposing a new companion tool

`install.sh` offers, never vendors, companion tools. To propose adding one:

- It must have its own public repo and its own install method (brew/npm/cargo/etc).
- No vendoring or forking — radin only shells out to the tool's documented
  install command, gated behind an explicit `y` confirmation.
- Open a PR adding an `install_if_confirmed` call in `install.sh` and a row in
  the README's companion-tools table.

## Editing agents/skills

`agents/radin-orchestrator.md`, `agents/radin-plan.md`, and
`skills/radin-review/SKILL.md` are synced copies — see `AGENTS.md`'s "Dev
loop" section for which direction edits flow in your setup. If you're editing
them directly in this repo (no `~/.config/.claude` fork), edit normally; if
you maintain a fork, edit there and run `./sync.sh`.

## Testing `sync.sh` / `install.sh` changes locally

```sh
bash -n sync.sh install.sh
shellcheck sync.sh install.sh
./sync.sh   # if you have a ~/.config/.claude fork; confirms the drift gate passes
```

## PR expectations

- `bash -n` clean on any changed script
- `shellcheck` clean (or documented exceptions only)
- Docs updated per the table in `AGENTS.md`'s "Doc-maintenance policy"
- If `agents/` or `skills/` were touched, re-run `./sync.sh` and confirm zero
  drift
