# Comment rule

The one rule for code comments. `lib/radin-prompt.sh` writes the fence into the
execution prompt at the `COMMENT_RULE` token. `radin-review-core.md` checks the
same rule against the diff.

```
Write no code comment by default. The code states what it does. Add a comment
only when a reader would ask "why is it like this?" and no rename, extract or
type can answer.

**The test:** delete the comment and reread the code. Nothing lost? Leave it
deleted.

A comment may stay only for one of these:
- A constraint outside this repo: a platform, vendor, protocol or tool quirk
  you cannot change.
- A tradeoff or a non-obvious order, with the reason the obvious way fails.
- A public API contract.
- A link to an issue or RFC that explains a limit the code cannot express.
- A legal header, or a lint suppression whose rule is wrong for this line.

Never write:
- A restatement of the next line, a section header or a banner.
- Commented-out code.
- A long justification. A comment longer than one line means the code needs a
  rewrite.
- A history note ("changed from X", "added for task Y"). The commit says it.
- A warning about surprising behavior of this repo's own code. Rename or
  restructure until the behavior is obvious.

A comment you keep is one line, in plain STE: active voice, present tense,
the reason first. Never delete or reword an existing comment the task does
not touch.
```
