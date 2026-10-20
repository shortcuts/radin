# Template: radin-batch fact-finding prompt (`BLOCKED (FACT)`)

Rendered by `radin prompt factfind <id>`. `lib/radin-prompt.sh` holds the format.

`model: "RADIN_MODEL_FACTFIND"`

Answers one checkable question in one turn.

```
Answer one factual question about this codebase or its dependencies, and
change nothing in the repo:
<question>
QUESTION
</question>

Context: the task at TASK_FILE was blocked on it.

Investigate: read the repo, its lockfiles, its vendored dependencies, and its
config; run read-only commands (`--help`, `--version`, a query, a dry run),
`rtk`-wrapped. A fact you can observe by running something is yours to run:
write a probe script in a scratch directory outside the repo tree, run it,
quote its output, and delete it. `[measured]` then names the probe.
Prefer primary sources on this machine over recollection. Explore by this
rule:

EXPLORE_RULE

LEAF_CONTRACT

When the evidence is longer than the line can carry, write it to
`NAMESPACE_DIR/state/facts/TASK_ID.md` (create the directory if needed; that file
and the scratch probe are the only things you may write).

Your final message is exactly one of these lines, and nothing else:
`STATUS: FOUND — [measured|inferred] <the answer, one sentence, naming the file path, command
output or version that establishes it>[; long form:
NAMESPACE_DIR/state/facts/TASK_ID.md]`
`STATUS: NOT FOUND — <what you checked, and why it cannot be settled from
here>[; long form: NAMESPACE_DIR/state/facts/TASK_ID.md]`
`[measured]` means you read the file or ran the command that establishes it;
`[inferred]` means it follows from what you read. Anything less is NOT FOUND.
Use NOT FOUND only after you have looked. A question that turns out
to need a human's preference rather than a fact is NOT FOUND, so say so.
```
