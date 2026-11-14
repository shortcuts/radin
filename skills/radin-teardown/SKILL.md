---
name: radin-teardown
description: |
  Use for /radin-teardown while /radin-batch or /radin-do runs. Stops the run
  from starting new tasks; the task in flight, the gate and the merge still finish.
<!-- host:claude -->
disable-model-invocation: true
<!-- /host -->
---
# Graceful Teardown

**Request the stop.** Run `RADIN_CLI state teardown`. From then on `task-next`
picks no new task, so the run loop reaches its end on its own.

**Carry on the run.** When this thread holds a running `/radin-batch` or
`/radin-do` loop, continue it from where it paused. Let every outstanding
sub-agent finish and record its `task-report`. Dispatch nothing new, and run
Phase 4.5 (gate), Phase 4.7 (merge) and Phase 5 (summary) as written in
`RADIN_LIB/radin-run.md`. Unstarted tasks stay `pending` for the next run.

**The test:** is a task already claimed? Yes: it finishes. No: it waits for the next run.

**Reply:** one line that the teardown is requested, then the run's Phase 5 summary. When no run is active, say so; the request clears at the next `radin-batch` or `radin-do` start.
