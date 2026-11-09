---
name: radin-uninstall
description: |
  Use for /radin-uninstall. Removes what install.sh put in the Claude Code,
  Codex and opencode setups: radin's skills, lib files, guidance blocks and rules.
disable-model-invocation: true
---
# Uninstall

**List the changes.** Run `"$HOME/.radin/bin/radin" uninstall --dry-run`. It changes nothing and prints each action.

**Ask about edited files.** When the output has a `KEPT (edited)` line, ask per `/var/folders/xk/9688pbzx5kv5bqrntk1dmdpc0000gn/T/tmp.P0fln7Maom/home/.radin/hosts/claude/lib/radin-ask-rule.md`: `Remove edited files too` or `Keep them`. Ask before the real run: that run deletes the ask rule.

**Remove.** Run `"$HOME/.radin/bin/radin" uninstall`. After `Remove edited files too`, run `"$HOME/.radin/bin/radin" uninstall --force`.

**Reply:** the real run's full output as-is; it lists what was removed and what was left untouched, with manual removal commands for the advisory companion tools.
