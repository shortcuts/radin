# Open-decisions rule

The one rule for what a cold start must decide before it can work. `lib/radin-prompt.sh`
writes the fence into the planning prompt at the `OPEN_DECISIONS_RULE`
token. `radin-record` Step 2 reads this file.

```
List what a cold start would have to decide that the entry and its plans do not
settle. Tag each question:
- **Fact**: checkable against the repo, its docs, or an API. Look it up
  yourself. Never ask the user for one.
- **Decision**: a judgment call only the user can make (a tradeoff, a scope
  boundary, a behavior choice). Naming even one plausible guess (a threshold, a
  naming choice, keep versus remove) makes it a Decision.

An item with no second reasonable way to do it has no Decision.
```
