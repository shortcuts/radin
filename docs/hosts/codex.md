# Codex CLI

This page covers radin on Codex CLI. For the installer steps, see [Install](../install.md).

## What radin writes

| Path | Content |
| --- | --- |
| `~/.agents/skills/radin-*` | radin's skills. Codex reads this user root |
| `$CODEX_HOME/AGENTS.md` (default `~/.codex/AGENTS.md`) | A radin block between `radin:begin` and `radin:end` markers |
| `~/.radin/hosts/agents/lib` | Rendered `.md` libs for the agents host |
| `~/.radin/backups/hooks.json.<stamp>.bak` | A copy of your `hooks.json`, made before the companion steps |

radin writes no `config.toml`, no `hooks.json` and no agent role file.
Companion hooks go into `$CODEX_HOME/hooks.json` through each companion's own installer.
Codex has no agent role files from radin, so sub-agents inherit the model of the session.

Codex has no version floor. `radin doctor` checks that the features radin uses respond.

Codex and opencode both read `~/.agents/skills`. With both installed, they share one render of radin's skills.
A skill of the same name in another location is your own configuration, and radin does not change it.

## First run

1. Start Codex in a repo.
2. Run `/hooks`. Review the new hooks and trust them once.

Codex does not run a new hook until you trust it. The installer cannot trust hooks for you.

## Check it

```sh
radin doctor
codex debug prompt-input | grep radin-batch
```

`radin doctor` prints a `NOTE` when the hooks are untrusted, and `OK` once the trust is recorded.
The Codex skills listing is informational: a `NOTE` there does not fail the check.

## Troubleshooting

**Hooks are untrusted.** `radin doctor` prints `Codex hooks untrusted`.
Open `/hooks` in Codex and trust the new hooks.

**A radin skill is not listed.** Check that `~/.agents/skills/radin-batch/SKILL.md` exists.
Then run `codex debug prompt-input` and look for `radin-batch`.
If the file is missing, run the installer again with `--only codex`.

**A skill asks a question and stops.** Codex Default mode refuses its question tool.
In Default mode, a radin skill asks one numbered plain-text question and waits for your reply.
Reply with the number or the text of your choice.

**The installer stops the Codex host with a conflict.** A file exists at a radin path, and radin did not install it or you edited it.
The other hosts still install. Move the file yourself, or run the installer again with `--only codex --force`.
`--force` moves the file to `~/.radin/backups/<timestamp>/` and installs radin's file.

**A companion replaced your hooks.** codebase-memory-mcp's installer may replace the `SessionStart` array in `hooks.json`.
This is not verified on Codex ([#1200](https://github.com/DeusData/codebase-memory-mcp/issues/1200)).
Compare `$CODEX_HOME/hooks.json` with `~/.radin/backups/hooks.json.<stamp>.bak`, and restore it by hand if needed.
