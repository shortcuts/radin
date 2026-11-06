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

To check against the real CLI, run `make verify-hosts VERIFY_ARGS="--only codex"`.
It installs radin into a temporary `HOME` and runs `codex debug prompt-input` there.
It fails when:

- `codex debug prompt-input` does not list every shipped skill or the `radin:begin` block.
- `radin doctor` does not print `OK       Codex lists radin skills`.
- a shipped skill is missing from `~/.agents/skills` or has no `name:` line.
- an unresolved token such as `@@skill:` or `RADIN_CLI` survives in an installed file or in the prompt input.

The target prints the hooks line from `radin doctor` and never judges it. You trust hooks in `/hooks`.

Prerequisites: a C compiler, and npm when you add `--install-missing`.
That flag installs the pinned `@openai/codex@0.166.0` into the temporary directory.

## Sign-off checklist

The epic is stable when every step passes on a real Codex.
Run the steps in order in a scratch repo, and fill the Result field of each step you run.
A step with an empty Result is unverified.

Tested on codex-cli 0.166.0 (npm `@openai/codex@0.166.0`), macOS 24.6.0 (arm64), 2026-11-06.
Steps 1 to 3, 10 and 11 ran in a temporary `HOME`, `XDG_CONFIG_HOME` and `CODEX_HOME`, with no model call.
The companion fetchers (`curl`, `brew`, `mise`, `npm`) were stubs, so no companion skill downloaded.

| # | Step | Result | Status |
| --- | --- | --- | --- |
| 1 | `./install.sh --yes --only codex` exits 0 and the manifest lists `codex`. | exit 0, manifest lists `codex` | measured |
| 2 | `radin doctor` finds the Codex CLI and prints no radin file as `MISSING`. | `codex found`; the only `MISSING` lines are companion skills (see Deviations) | measured |
| 3 | `make verify-hosts VERIFY_ARGS="--only codex"` prints `OK codex`. | `codex debug prompt-input` lists every shipped skill and the `radin:begin` block; doctor prints `OK       Codex lists radin skills` | measured |
| 4 | Record two entries with `/radin-record`. `radin --host agents backlog show` lists both. | | unverified (needs a model) |
| 5 | Plan one entry with `/radin-plan`. | | unverified (needs a model) |
| 6 | Run `/radin-batch` on both entries. | | unverified (needs a model) |
| 7 | `git log` shows one commit per task and `git status` is clean. | | unverified (needs a model) |
| 8 | `radin --host agents` opens the TUI and `q` quits it. | | unverified (needs a TTY) |
| 9 | A leaf that hits a decision asks through the question tool, or in Default mode one numbered plain-text question. | | unverified (needs a model) |
| 10 | `./install.sh --yes --update` exits 0 and changes no radin file. | exit 0; the file set differs only by Codex's own plugin cache and lock files | measured |
| 11 | `radin uninstall` exits 0 and leaves no radin file outside `~/.radin/backups`. | exit 0; `~/.radin` is gone, `$CODEX_HOME/AGENTS.md` is empty, no radin file remains under `~/.agents` | measured |

### Deviations

- Doctor ends with `15 check(s) failed`. Each one is a `MISSING` companion skill under `~/.agents/skills`, because the fetchers were stubs. No radin file failed.
- `thermo-nuclear download failed` prints on each install and update for the same reason. radin's own files are unaffected.
- Doctor prints `NOTE     no Codex hooks found`, because the stubbed companion step wrote no `hooks.json`. Step 3 never judges it, and trusting hooks in `/hooks` needs a real session.
- Codex's own `~/.codex/skills/.system` files stay after uninstall. They are Codex's, not radin's.

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
