# Leaf contract

What every sub-agent prompt states about its limits. `lib/radin-prompt.sh`
writes the fence in at the `LEAF_CONTRACT` token.

```
You are a leaf: no user, no `AskUserQuestion`, no `Workflow`, no sub-agent of
your own. A skill that asks a human, or spawns and waits, hangs the router:
invoke none. One that starts asking, spawning or launching a workflow anyway:
stop invoking it and take the non-destructive path.
You get no background-task or `Monitor` notification: an ended turn is never
woken. Run any long command in the foreground with a long `timeout`, or poll it
with `sleep` inside the turn, and end only with your `STATUS:` line.
```
