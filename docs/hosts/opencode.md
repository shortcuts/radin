# opencode

This page covers radin on opencode. For the installer steps, see [Install](../install.md).

## What radin writes

| Path | Content |
| --- | --- |
| `~/.agents/skills/radin-*` | radin's skills. opencode reads this user root |
| `$XDG_CONFIG_HOME/opencode/AGENTS.md` (default `~/.config/opencode/AGENTS.md`) | A radin block between `radin:begin` and `radin:end` markers |
| `~/.config/opencode/agents/radin-<kind>.md` | One agent file each for `planning`, `execution`, `review`, `debug`, `factfind`, `gate` and `merge` |
| `~/.config/opencode/opencode.json` | The `external_directory` allow rule for `~/.radin/**` |
| `~/.radin/backups/opencode.json.<stamp>.bak` | A copy of the config, made before the rule is written |

`OPENCODE_CONFIG` names one file. When set, radin writes the allow rule to that file and nowhere else.
Each agent file sets no `model`, so it uses the model of the session.
Each agent file denies `question` and `task`, so a leaf cannot wait on you or start more agents.
radin writes no `tools: [...]` array into agent files. opencode 1.x does not boot with that array.

opencode 1.18.29 or newer is required. `radin doctor` prints `INVALID` for an older version.

### The read rule

opencode asks before it reads any path outside the project. radin keeps its files in `~/.radin`,
so each read there would prompt you.

The installer adds this rule to the opencode config:

```json
{
  "permission": {
    "external_directory": {
      "/Users/you/.radin/**": "allow"
    }
  }
}
```

The path is your own `~/.radin`. The installer copies the config to `~/.radin/backups/` before it writes the rule.

If the config holds comments (JSONC), or `external_directory` is a string, the installer cannot edit it safely.
It then prints the exact rule. Merge that rule into `permission` by hand.

## First run

1. Start opencode in a repo.
2. Run a radin command, such as `/radin-batch`, and check that no read prompt appears for `~/.radin`.

## Check it

```sh
radin doctor
```

`radin doctor` checks the version, each `radin-*.md` agent file and the `external_directory` rule.
A `MISSING` line for the rule means the rule is gone. Run the installer again with `--only opencode`.

To check against the real CLI, run `make verify-hosts VERIFY_ARGS="--only opencode"`.
It installs radin into a temporary `HOME` and runs `opencode debug agents --standalone` and `opencode debug config --standalone`.
It fails when:

- one of the seven `radin-<kind>` agents is missing from the agents listing.
- the `~/.radin/**` rule is missing from the config output.
- a shipped skill is missing from `~/.agents/skills` or has no `name:` line.
- an unresolved token such as `@@skill:` or `RADIN_CLI` survives in an installed file.

Prerequisites: npm, when you add `--install-missing`.
That flag installs the pinned `@opencode/cli@2.2.5` into the temporary directory.
Without it, the target skips the host when `opencode` is not on `PATH`.

Limits:

- opencode 2.2.5 has no command that lists skills, so the skill check reads the installed files.
- opencode drops a malformed config or agent file without an error, so the rule and agent checks double as the parse check.
- Only 2.x is verified. The 1.x versions are untested.

## Sign-off checklist

The epic is stable when every step passes on a real opencode.
Run the steps in order in a scratch repo, and fill the Result field of each step you run.
A step with an empty Result is unverified.

Tested on opencode v2.2.5 (mise), macOS 24.6.0 (arm64), 2026-11-06.
Steps 1 to 3, 10 and 11 ran in a temporary `HOME`, `XDG_CONFIG_HOME` and `CODEX_HOME`, with no model call.
The companion fetchers (`curl`, `brew`, `mise`, `npm`) were stubs, so no companion skill downloaded.

| # | Step | Result | Status |
| --- | --- | --- | --- |
| 1 | `./install.sh --yes --only opencode` exits 0 and the manifest lists `opencode`. | exit 0, manifest lists `opencode` | measured |
| 2 | `radin doctor` finds the opencode CLI and prints no radin file as `MISSING`. | `opencode found`; the only `MISSING` lines are companion skills (see Deviations) | measured |
| 3 | `make verify-hosts VERIFY_ARGS="--only opencode"` prints `OK opencode`. | `opencode debug agents --standalone` lists all seven `radin-<kind>` agents; `opencode debug config --standalone` holds the `~/.radin/**` rule | measured |
| 4 | Record two entries with `/radin-record`. `radin --host agents backlog show` lists both. | | unverified (needs a model) |
| 5 | Plan one entry with `/radin-plan`. | | unverified (needs a model) |
| 6 | Run `/radin-batch` on both entries. | | unverified (needs a model) |
| 7 | `git log` shows one commit per task and `git status` is clean. | | unverified (needs a model) |
| 8 | `radin --host agents` opens the TUI and `q` quits it. | | unverified (needs a TTY) |
| 9 | A leaf that hits a decision asks through the question tool. | | unverified (needs a model) |
| 10 | `./install.sh --yes --update` exits 0 and changes no radin file. | exit 0; the only new file is `~/.radin/backups/opencode.json.<stamp>.bak` | measured |
| 11 | `radin uninstall` exits 0 and leaves no radin file outside `~/.radin/backups`. | exit 0; `~/.radin` and every radin agent file are gone, and `opencode.json` holds no radin rule | measured |

### Deviations

- Doctor ends with `15 check(s) failed`. Each one is a `MISSING` companion skill under `~/.agents/skills`, because the fetchers were stubs. No radin file failed.
- `thermo-nuclear download failed` prints on each install and update for the same reason. radin's own files are unaffected.
- Uninstall leaves `opencode.json` with `"external_directory": {}` and the ponytail plugin entry, and leaves an empty `AGENTS.md`. The plugin entry belongs to the companion.
- Each update writes one more `~/.radin/backups/opencode.json.<stamp>.bak`.

## Troubleshooting

**opencode asks permission for every `~/.radin` read.** The rule is missing or was not written.
Run `radin doctor`. If it prints `MISSING`, run the installer again with `--only opencode`.
If the config holds comments, merge the rule the installer printed.

**opencode fails to start after install.** Run `radin doctor` and check each `radin-*.md` file it lists.
A file you edited stays as it is, and the installer prints `kept`.
To restore radin's version, run the installer again with `--only opencode --force`.
`--force` moves your copy to `~/.radin/backups/<timestamp>/`.

**opencode is below 1.18.29.** `radin doctor` prints `INVALID`. Upgrade opencode, then run `radin doctor` again.

**A radin skill is missing or loads twice.** Codex and opencode both read `~/.agents/skills`.
A skill of the same name in another location is your own configuration. radin does not change it.
