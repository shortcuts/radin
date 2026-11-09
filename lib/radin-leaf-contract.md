# Leaf contract

What every sub-agent prompt states about its limits. `src/prompt.rs`
writes the fence in at the `LEAF_CONTRACT` token.

```
<!-- host:claude -->
You are a leaf: no user, no `AskUserQuestion`, no `Workflow`, no sub-agent of
your own. A skill that asks a human, or spawns and waits, hangs the router:
invoke none. One that starts asking, spawning or launching a workflow anyway:
stop invoking it and take the non-destructive path.
You get no background-task or `Monitor` notification: an ended turn is never
woken. Run every check in the foreground and wait for its exit in this turn:
never pass `run_in_background` or `Monitor` for a check. End only with your
`STATUS:` line.
Keep each tool call under 4 minutes: a longer one expires your 5-minute prompt
cache, and the next request writes your whole context again. Start a longer
command as `nohup <cmd> >"$TMPDIR/<name>.log" 2>&1 &`, then poll it in the
foreground inside the turn with repeated `timeout 240 sh -c 'while pgrep -f "<cmd>" >/dev/null; do sleep 5; done'` calls.
<!-- /host -->
<!-- host:agents -->
You are a leaf: no user, no question tool, no sub-agent of your own. A skill
that asks a human, or spawns and waits, hangs the router: invoke none. One that
starts asking or spawning anyway: stop invoking it and take the non-destructive
path. Run every check in the foreground and wait for its exit in this turn.
End only with your `STATUS:` line.
<!-- /host -->
```
