<p align="center">
  <strong>🐀 radin</strong>
</p>

<p align="center">
  <em>Too cheap to pay full price for a whole AI tool stack — so it went shopping for you.</em>
</p>

<p align="center">
  <sub>"Radin" is French slang for miser. Hence the rat.</sub>
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue?style=flat" alt="License"></a>
  <a href="AGENTS.md"><img src="https://img.shields.io/badge/platform-macOS%20%7C%20Linux-lightgrey?style=flat" alt="macOS | Linux"></a>
</p>

A Claude Code plugin for a solo dev on a small subscription. One `curl | bash`
gives you:

- **A backlog-driven workflow.** Tasks live as files in your repo, so they
  survive the conversation. Plan them, execute them one commit at a time,
  review the result. Any run resumes where it stopped.
- **A curated token-reduction stack**, installed whole: rtk, caveman,
  ponytail, codebase-memory-mcp, headroom, thermo-nuclear, mattpocock-skills.
  radin delegates to them instead of reimplementing them. It never forks or
  vendors them.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/shortcuts/radin/main/install.sh | bash
```

Needs `curl`, `tar`, `bash`, and the `claude` CLI. `radin tui` is C: install
builds it with `cc` (Xcode Command Line Tools on macOS, gcc on Linux) and
skips it with a warning when no compiler is there. Companion tools pull their
own stacks; one that fails is reported and skipped, and radin still installs.
Homebrew (`rtk`), `python3` (headroom, codebase-memory-mcp config) are
optional but recommended.

Install asks two questions, both about `radin-execute`: concurrency and
sub-agent models. Add `-s -- --yes` to take the defaults.

Update the whole stack — radin plus every companion — with `radin update`. The
answers come from `~/.claude/.radin/manifest.json`, so nothing is re-asked.

## Use it

| Command | What it does |
| --- | --- |
| `/radin-record` | Turn a bug, idea, or aside raised mid-session into a backlog task |
| `/radin-plan` | Write a step-by-step plan for one task, touching no code |
| `/radin-execute` | Work the backlog: prioritize, implement, commit, one task per commit |
| `/radin-review` | Strict quality pass over a scope; kept findings become tasks |
| `/radin-show` | Print the backlog |
| `/radin-stats` | Every companion tool's own savings report, side by side |
| `/radin-doctor` | Verify the install, report unreachable companions |
| `/radin-uninstall` | Remove what `install.sh` put in `~/.claude` |
| `radin tui` | Full-screen backlog browser for humans. No agent involved; `?` lists keys |

Typical loop: record → (plan) → execute → review, whose findings feed the next
execute. Each skill runs in your own conversation, so it can ask you
questions; only leaf work goes to sub-agents. `/radin-execute` confirms the
order before it starts, and every task's state is on disk, so interrupting it
costs nothing. Want your thread free? Dispatch it from `claude agents` or a
second `claude` session — the worktree-per-task answer keeps concurrent runs
off each other's checkout.

## Where things live

One directory per repo: `<repo-root>/.claude/.radin/` — the backlog index, one
markdown file per task, plans, reviews, and execution state. Commit it to
share the backlog with your team, or gitignore it to keep it private. radin
never touches your `.gitignore`.

Every tool goes through the `radin` CLI (`radin backlog`, `radin state`), so
nothing hand-edits those files. A task carries a category
(`feat`/`fix`/`chore`/`refactor`), an optional priority and `depends_on`, and
can sit under an epic whose `DESCRIPTION.md` every child inherits.

## What it shops for

| Tool | What it does |
| --- | --- |
| [rtk](https://github.com/rtk-ai/rtk) | Wraps dev commands, cuts their output 60-90% |
| [caveman](https://github.com/JuliusBrussee/caveman) | Terse agent prose, ~65% fewer tokens |
| [ponytail](https://github.com/DietrichGebert/ponytail) | Makes the agent think like the laziest senior dev in the room |
| [codebase-memory-mcp](https://github.com/DeusData/codebase-memory-mcp) | Indexes the repo into a knowledge graph, so the agent asks instead of grepping |
| [headroom](https://github.com/headroomlabs-ai/headroom) | Whole-session context compression, complements rtk's per-command one |
| [thermo-nuclear](https://github.com/cursor/plugins/tree/main/cursor-team-kit/skills/thermo-nuclear-code-quality-review) | Maintainability review skill |
| [mattpocock-skills](https://github.com/mattpocock/skills) | Engineering skills; radin delegates interviewing and research here |

Two caveats: a graph answer is a pointer, never proof of absence — read the
file before editing. And after `codebase-memory-mcp update`, run
`radin cbm-config repair`, because that update reruns a config write which
drops other tools' hooks. Full list in
[docs/technical-constraints.md](docs/technical-constraints.md).

Hacking on radin itself? [AGENTS.md](AGENTS.md),
[CONTRIBUTING.md](CONTRIBUTING.md).
