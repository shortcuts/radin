---
name: radin-uninstall
description: |
  Remove everything install.sh copied into ~/.claude -- radin's skills
  and lib scripts. Use for /radin-uninstall, "uninstall radin",
  "remove radin", "tear down radin", "get rid of radin".
---
# Uninstall

Removes every file `install.sh` copied into `~/.claude`, and only those: each
`radin-*` skill directory (this one included) and radin's lib scripts under
`~/.claude/.radin/lib/`.

## Step 1: Run it

```bash
RADIN_CLI uninstall
```

## Step 2: Report it

Print the full output to the user as-is. It already lists what was removed and
what was left untouched, with manual removal commands for the advisory
companion tools.
