# Install, update and uninstall

This guide installs radin and keeps it current. It assumes you use macOS or Linux.
For every flag and path, see [Reference](reference.md).

## Install radin

1. Check that `curl`, `tar`, `bash` and the CLI of each host you pick are on your `PATH`.
2. Optional: install a C compiler (Xcode Command Line Tools on macOS, gcc on Linux).
   Without one, the installer skips the TUI and `radin repair` with a warning.
3. Run the installer:

   ```sh
   curl -fsSL https://raw.githubusercontent.com/shortcuts/radin/main/install.sh | bash
   ```

4. Answer three questions: sub-agent models, the package manager for the companion tools
   (`brew`, `mise` or `curl`), and sub-agent effort.
   To accept every default, add `-s -- --yes` after `bash`.
   To pick hosts, add `--only claude`, `--only codex` or `--only opencode`, or a comma list.
   `--list` prints each host and whether it is detected. `--dry-run` prints every write and changes nothing.
   Per-host setup: [Codex](hosts/codex.md), [opencode](hosts/opencode.md).
5. Run `radin doctor` to check the install.

The installer reports a companion tool that fails to install, skips it, and finishes the install.
To trace an install that hangs or fails, add `-s -- --verbose`.

## Update radin

```sh
radin update
```

It asks no question and keeps your sub-agent models.
It reapplies every companion's configuration and installs only the companions that are missing.
To update the companions too, run `install.sh` again.

The first install after the move to `~/.radin` relocates `~/.claude/.radin` there.
It then asks you to restart open Claude sessions, because they hold the old path.

## Existing files

The installer checks every skill and lib file it writes against `~/.radin/manifest.json` before it writes any.

- A path radin did not install stops that host. The other hosts install. Codex and opencode share one render, so they stop together.
- A file you edited after radin installed it stays as it is. The installer prints `kept <path>`.
- `--force` moves either one to `~/.radin/backups/<timestamp>/` and installs radin's file. The manifest `backups` map lists each move.

`--dry-run` prints `conflict`, `keep` and `backup` lines for the same cases and writes nothing.

## Repair hooks after a companion update

After `codebase-memory-mcp update`, run:

```sh
radin repair
```

That update reruns a config write that drops other tools' hooks. `radin repair` restores them.
radin keeps a snapshot of `~/.claude/settings.json` and `~/.claude.json` in
`~/.radin/backups/` and never deletes one.

## Uninstall radin

Run `/radin-uninstall`, or `radin uninstall`. It removes radin's files from every installed host in one run, strips the radin block from each `CLAUDE.md` and `AGENTS.md`, and removes the opencode allow rule.
It keeps a file you edited since install. `radin uninstall --dry-run` lists every action and changes nothing. `radin uninstall --force` removes the edited files too.
Companion tools and `~/.radin/backups` stay.
To remove codebase-memory-mcp's own changes, run `codebase-memory-mcp uninstall`.
