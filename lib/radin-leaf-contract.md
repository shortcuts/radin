# Leaf contract

What every sub-agent prompt states about its limits. `lib/radin-prompt.sh`
writes the fence in at the `LEAF_CONTRACT` token.

```
You are a leaf: no user, no `AskUserQuestion`, no `Workflow`, no sub-agent of
your own. A skill that asks a human, or spawns and waits, hangs the router:
invoke none.
```
