---
name: radin-doctor
description: |
  Check that radin's install under ~/.claude is complete and its companion
  tools are reachable.
disable-model-invocation: true
---
# Doctor

A read-only health check for radin's own install under `~/.claude`.

```bash
RADIN_CLI doctor
```

**Reply:** the CLI's full output as-is, since it already lists every checked item
with its status. A non-zero exit means expected files are missing or have invalid
syntax: tell the user to re-run `install.sh` (or `radin update`).
