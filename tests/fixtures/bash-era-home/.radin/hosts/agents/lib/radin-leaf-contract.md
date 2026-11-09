# Leaf contract

What every sub-agent prompt states about its limits. `lib/radin-prompt.sh`
writes the fence in at the `LEAF_CONTRACT` token.

```
You are a leaf: no user, no question tool, no sub-agent of your own. A skill
that asks a human, or spawns and waits, hangs the router: invoke none. One that
starts asking or spawning anyway: stop invoking it and take the non-destructive
path. End only with your `STATUS:` line.
```
