## Summary

## Checklist

- [ ] `bash -n` passes on any changed script
- [ ] `shellcheck` passes on any changed script (or exceptions documented)
- [ ] Docs updated per the table in `AGENTS.md`'s "Doc-maintenance policy"
- [ ] If `agents/` or `skills/` were touched: `./sync.sh` re-run, drift gate
      reports zero differences
