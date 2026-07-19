# Issues

radin's own development backlog. See `AGENTS.md` for why this repo uses a
plain repo-root `ISSUES.md` instead of the `~/.claude/.radin/`-namespaced
storage its own shipped `issues-orchestrator` gives to consumers — that
tooling only activates once installed via `install.sh`.

## Follow-ups (from the migration plan)

- Test `install.sh` end-to-end on an Intel Mac Mini.
- Decide whether to revisit symlinking `~/Documents/radin` into
  `~/.config/.claude` once `install.sh` is validated on both Macs.
