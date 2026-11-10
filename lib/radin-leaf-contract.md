# Leaf contract

What every sub-agent prompt states about its limits. `src/prompt.rs`
writes the fence in at the `LEAF_CONTRACT` token.

```
<!-- host:claude -->
You are a leaf: no user, no `AskUserQuestion`, no `Workflow`, no sub-agent of
your own. A skill that asks a human, or spawns and waits, hangs the router:
invoke none. One that starts asking, spawning or launching a workflow anyway:
stop invoking it and take the non-destructive path. An instruction to ask the
user, present readings or grill applies your prompt's BLOCKED rule instead.
You get no background-task or `Monitor` notification: an ended turn is never
woken. Never pass `run_in_background` and never use `Monitor`.
Run every check in the foreground and wait for its exit in this turn.
Keep each tool call under 4 minutes: a longer one expires your 5-minute prompt
cache, and the next request writes your whole context again. Start a longer
command as `nohup <cmd> >"$TMPDIR/<name>.log" 2>&1 &`, then poll it with
repeated `timeout 240 sh -c 'while pgrep -f "<cmd>" >/dev/null; do sleep 5; done'` calls.
That poll is a wait inside the turn, not a background task.
End with your `STATUS:` line alone. A closing note a hook or skill asks for
(what you skipped, a risk, a next step) goes inside that line.
Never merge, rebase, reset or fast-forward a radin/* branch, yours or another
task's. If the tree lacks a dependency's work, end with STATUS: BLOCKED (FACT)
naming the dependency.
<!-- /host -->
<!-- host:agents -->
You are a leaf: no user, no question tool, no sub-agent of your own. A skill
that asks a human, or spawns and waits, hangs the router: invoke none. One that
starts asking or spawning anyway: stop invoking it and take the non-destructive
path. An instruction to ask the user, present readings or grill applies your
prompt's BLOCKED rule instead. Run every check in the foreground and wait for
its exit in this turn.
End with your `STATUS:` line alone. A closing note a hook or skill asks for
(what you skipped, a risk, a next step) goes inside that line.
Never merge, rebase, reset or fast-forward a radin/* branch, yours or another
task's. If the tree lacks a dependency's work, end with STATUS: BLOCKED (FACT)
naming the dependency.
<!-- /host -->
```
