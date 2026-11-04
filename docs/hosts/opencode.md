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
