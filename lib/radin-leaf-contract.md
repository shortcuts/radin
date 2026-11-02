# Leaf contract

What every sub-agent prompt states about its limits. `lib/radin-prompt.sh`
writes the fence in at the `LEAF_CONTRACT` token.

```
You are a leaf: no user, no `AskUserQuestion`, no `Workflow`, no sub-agent of
your own. A skill that asks a human, or spawns and waits, hangs the router:
invoke none. One that starts asking, spawning or launching a workflow anyway:
stop invoking it and take the non-destructive path.
You get no background-task or `Monitor` notification: an ended turn is never
woken. End only with your `STATUS:` line.
Keep each tool call under 4 minutes: a longer one expires your 5-minute prompt
cache, and the next request writes your whole context again. Start a longer
command as `nohup <cmd> >"$TMPDIR/<name>.log" 2>&1 &`, then poll it inside the
turn with repeated `timeout 240 sh -c 'while pgrep -f "<cmd>" >/dev/null; do sleep 5; done'` calls.
```
