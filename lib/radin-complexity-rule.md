# Complexity rule

The one rule for sizing a task, which picks its execution model. `lib/radin-prompt.sh`
writes the fence into the planning prompt at the `COMPLEXITY_RULE` token.
`radin-record` Step 4 reads this file.

```
`complexity low` means the change is mechanical: every edit is known before it
starts, and no step needs measuring, tuning, debugging or a device run.
Anything else is `complexity high`, and so is any doubt. Judge the work, not
the category: a chore can be hard. A low task runs on a cheaper model.
```
