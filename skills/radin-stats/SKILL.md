---
name: radin-stats
description: |
  Show the stats/gain output of every companion tool that ships one, side by
  side.
disable-model-invocation: true
---
# Stats Roundup

Print each tool's own stats or gain command, back to back. Compute no merged
total. The units differ (per-session tokens, benchmark medians, a per-repo
ledger). Display each output as-is.

## Run every source

Run all five without probing. A source that is not installed fails visibly;
that failure is the skip, so do not retry it.

- **`/caveman:caveman-stats`** -- measured: real per-session token usage and
  savings, read from the session log itself.
- **`/ponytail:ponytail-gain`** -- benchmark: ponytail's published scoreboard.
  Not this session, and not this repo.
- **`/ponytail:ponytail-debt`** -- measured: ponytail's per-repo ledger of
  deferred shortcuts, if the repo has one.
- **`rtk gain`** -- measured: rtk's token-savings ledger (pass `-p` to scope it
  to the current project).
- **`radin stats`** -- measured: skill, slash-command and sub-agent use on this device, per vendor, plus each radin repo's journal totals. Read from Claude Code transcripts, so it covers every companion.

**Reply:** each source's output as-is, in the order listed, with no merged total.
