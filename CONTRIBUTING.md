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
`skills/radin-review/SKILL.md` are authored directly in this repo — this repo
is the source of truth, no external fork, no sync step. Edit them normally.

## Testing `install.sh` changes locally

```sh
bash -n install.sh
shellcheck install.sh
```

## PR expectations

- `bash -n` clean on any changed script
- `shellcheck` clean (or documented exceptions only)
- Docs updated per the table in `AGENTS.md`'s "Doc-maintenance policy"
