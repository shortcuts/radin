---
name: radin-show
description: |
  Print the current project's backlog to the terminal.
disable-model-invocation: true
---
# Show Backlog

Print the current project's backlog as markdown.

```bash
RADIN_CLI backlog show
```

Pass a category when the user narrows the scope ("show me fix items"):
`RADIN_CLI backlog show fix`. Otherwise pass none.

It exits 1 with "no backlog" when the project has none. Tell the user that,
point them at `radin-record` or `radin-review` to start one, and create no
file.

**Reply:** the CLI's output as-is; it already orders and formats it.
