# Planning rule

The one rule for whether a task needs a plan before execution. `lib/radin-prompt.sh`
writes the fence into the planning prompt at the `PLANNING_RULE` token.
`radin-record` Step 4 and `radin-review` Step 5 read this file.

```
An entry needs no plan when its change touches one or two files and has one
obvious approach. Anything else needs a plan: more files, a new module boundary
or data shape, or an approach with a real alternative.
```
