# Shared: radin-execute Final Summary

`radin-execute` reads this file at Phase 5, once the execution loop has
exited. It holds the residual-changes check and the report template, so a
session that never reaches Phase 5 never loads them.

1. Run `dirty-check "$REPO_ROOT"`. Empty: note "no residual changes".
   Non-empty: never commit it, because unknown changes are the user's call.
   Park it with `radin-state.sh stash "$REPO_ROOT" "radin-execute: session
   end, untracked to any task"` and record the ref. Changes under
   `.claude/.radin/` stay as they are.
2. Report where the commits actually landed. The Phase 0.5 answers decide the
   wording, never the template below:
   - Either answer was yes: every commit sits on `radin/<task-id>`, in
     worktree `$REPO_ROOT-<task-id>` when there was one, and nothing is
     merged into the branch the user is sitting on. Say that per task, with
     the merge command. Bare hashes read as "committed to my repo", and then
     the user finds their checkout untouched.
   - Both were no: the commits are on the user's current branch in
     `$REPO_ROOT`. Report `<title> — <hash>` and no merge command. A branch
     or worktree named here that the user declined is a bug in your report.
3. Leave failed and blocked backlog entries in place. If `radin-backlog.sh
   list` shows a duplicate id or title from manual edits, flag it in the
   summary rather than guessing which copy to remove.
4. Collect all commit hashes recorded this session, plus every `failed` and
   `blocked` entry in `BACKLOG_STEPS.json` with its `note`. Mark any task the
   refuter returned `UNVERIFIED` for, so the user knows which commits nothing
   checked. A refuter's `/radin-review` pass logs its own findings as backlog
   entries, so don't restate them here: say how many net-new entries this
   session added, per `radin-backlog.sh count`.
5. Report. This is the primary deliverable of any session with failures:

```
✅ Session complete: <N> succeeded, <M> failed, <K> awaiting your decision.

Succeeded (per step 2; drop the branch/worktree/merge parts when both modes were no):
- <task title> — <commit hash> [on <branch>] [in <worktree path>]. [Merge: git merge <branch>] [unverified: <why the refuter could not check it>]

Failed (left in the backlog for retry):
- <task title> — <reason>. Recover: <concrete command(s)>.

Needs your decision (left in the backlog, nothing implemented):
- <task title> — <question>. Options: <options>. Recommendation: <recommendation>.

Deferred at your request (left in the backlog):
- <task title>

Stashes created this session:
- <stash ref> — <what it holds>, in <dir>. Recover: git -C <dir> stash pop / git -C <dir> stash show -p <ref>.

Skills dropped as unrunnable by a sub-agent (run them yourself):
- <task title> — <skill>: asks the user or spawns its own agent.
```

Every failed line names why and what to run next, never just "failed".
