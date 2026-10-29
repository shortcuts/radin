# Install, update and uninstall

This guide installs radin and keeps it current. It assumes you use macOS or Linux.
For every flag and path, see [Reference](reference.md).

## Install radin

1. Check that `curl`, `tar`, `bash` and the `claude` CLI are on your `PATH`.
2. Optional: install a C compiler (Xcode Command Line Tools on macOS, gcc on Linux).
   Without one, the installer skips the TUI and `radin repair` with a warning.
3. Run the installer:

   ```sh
   curl -fsSL https://raw.githubusercontent.com/shortcuts/radin/main/install.sh | bash
   ```

4. Answer three questions: sub-agent models, the package manager for the companion tools
   (`brew`, `mise` or `curl`), and sub-agent effort.
   To accept every default, add `-s -- --yes` after `bash`.
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

## Repair hooks after a companion update

After `codebase-memory-mcp update`, run:

```sh
radin repair
```

That update reruns a config write that drops other tools' hooks. `radin repair` restores them.
radin keeps a snapshot of `~/.claude/settings.json` and `~/.claude.json` in
`~/.claude/.radin/backups/` and never deletes one.

## Uninstall radin

Run `/radin-uninstall` in Claude Code. It removes what `install.sh` put in `~/.claude`.
To remove codebase-memory-mcp's own changes, run `codebase-memory-mcp uninstall`.
