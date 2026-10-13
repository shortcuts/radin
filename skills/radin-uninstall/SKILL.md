---
name: radin-uninstall
description: |
  Remove everything install.sh copied into ~/.claude: radin's skills and lib
  scripts.
disable-model-invocation: true
---
# Uninstall

Removes every file `install.sh` copied into `~/.claude`, and only those.

```bash
RADIN_CLI uninstall
```

**Reply:** the CLI's full output as-is; it already lists what was removed and what
was left untouched, with manual removal commands for the advisory companion tools.
