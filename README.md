<p align="center">
  <strong>🐀 radin</strong>
</p>

<p align="center">
  <em>Too cheap to pay full price for a whole AI tool stack — so it went shopping for you.</em>
</p>

<p align="center">
  <sub>"Radin" is French slang for a miser. Hence the rat.</sub>
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue?style=flat" alt="License"></a>
  <a href="AGENTS.md"><img src="https://img.shields.io/badge/platform-macOS%20%7C%20Linux-lightgrey?style=flat" alt="macOS | Linux"></a>
  <a href="CHANGELOG.md"><img src="https://img.shields.io/badge/status-scaffold-orange?style=flat" alt="Status: scaffold"></a>
</p>

<p align="center">
  <a href="#quickstart">Quickstart</a> ·
  <a href="#tools-you-get">Tools you get</a>
</p>

---

An opinionated agentic stack, one script deep, baking in the most efficient (and safe) token-reduction tools around.

## Install

> Needs `curl`, `tar`. [Homebrew](https://brew.sh) is optional -- used for
> companion-tool installs when present, but not required on Linux.

```sh
# macOS · Linux · WSL
curl -fsSL https://raw.githubusercontent.com/shortcuts/radin/main/install.sh | bash
```

## Update

```sh
# macOS · Linux · WSL
curl -fsSL https://raw.githubusercontent.com/shortcuts/radin/main/install.sh | bash -s -- --force
```

## The backlog lifecycle

`BACKLOG.md` is your repo's backlog. It lives outside your repo, in
`~/.claude/.radin/projects/<repo-slug>/BACKLOG.md`. Every radin tool reads
from or writes to this one file.

A typical flow:

1. **Capture.** Something comes up mid-session — a bug, an idea, feedback
   from a teammate. Run `radin-record` to turn it into a backlog entry.
2. **Plan (optional).** Point `radin-plan` at one entry to write a
   step-by-step plan for it, without touching any code. Repeat per entry you
   want planned ahead of time.
3. **Execute.** Run `radin-execute` to work through the backlog,
   entry by entry, committing as it goes.
4. **Review.** Run `radin-review` against a commit, PR, or directory. Every
   finding becomes a new backlog entry, ready for the next pass of step 3.

## Tools you get

### Homemade

| Tool | What it does |
| --- | --- |
| `radin-execute` | Chews through `BACKLOG.md`, one task at a time, committing as it goes |
| `radin-plan` | Writes a plan for one backlog entry you point it at, instead of touching code |
| `radin-review` | Strict code-quality pass, findings logged straight back into the backlog |
| `radin-record` | Logs feedback/bugs/ideas raised mid-session as `BACKLOG.md` entries |
| `radin-show` | Prints the current project's `BACKLOG.md` |
| `radin-setup-hooks` | Wires up per-repo hooks/MCP config for companion tools |
| `radin-stats` | Shows each installed companion tool's own stats/gain output, side by side |

Some of these delegate to other skills under the hood, instead of
reimplementing review or style logic themselves:

| Tool | Delegates to |
| --- | --- |
| `radin-execute` | `/ponytail` (plan-or-skip gate, per-task implementation), `/radin-plan` (only for tasks judged complex enough), `/caveman-commit` (commit message), `/radin-review` (optional end-of-session review) |
| `radin-plan` | `/ponytail` (split judgment and plan writing), `/thermo-nuclear` + `/ponytail-review` (reviewing the plan itself before handoff) |
| `radin-review` | `/thermo-nuclear` (code-quality pass), `/ponytail-review` or `/ponytail-audit` (over-engineering pass) |

#### `radin-record`

Log something raised mid-conversation, before it gets lost.

```
/radin-record log the auth timeout bug we just found
```

Result: a new `### <title>` entry appended under `## fix` in `BACKLOG.md`,
with the bug described in enough detail for a future session to act on it
with no other context.

#### `radin-plan`

Write a plan for one backlog entry, without writing any code. Judges
whether the entry's scope should split into multiple independent plans,
and confirms with you before splitting.

```
/radin-plan the auth timeout bug
```

Result: one plan file per plan under
`~/.claude/.radin/projects/<repo-slug>/plans/` (more than one if the entry
was split), each reviewed with `/thermo-nuclear` and `/ponytail-review`
before handoff — any findings are fixed directly in the plan file — and a
`**Plan:** <path>` line appended to the entry in `BACKLOG.md` per plan
produced.

#### `radin-execute`

Work through the backlog end to end: prioritize, implement, test, commit —
one entry at a time. Uses an existing plan from `radin-plan` if the entry
already has one. If not, asks `/ponytail` whether the task is straightforward
enough to implement directly — only tasks judged genuinely complex go
through `/radin-plan` first.

```
/radin-execute
```

Result: each entry is implemented and committed in its own commit. Finished
entries are removed from `BACKLOG.md`; failed ones stay, marked for retry.
At the end it can optionally run a `/thermo-nuclear` review of the session
and log the findings back to the backlog as new entries.

#### `radin-review`

Run a strict quality review over a chosen scope and log findings to the
backlog instead of printing them to the terminal.

```
/radin-review #123
```

Also accepts a commit hash, a directory path, or a natural-language range
like `"commits since Monday"`. Result: one `BACKLOG.md` entry per finding,
classified as `fix` (a real bug) or `refactor` (structural), under the
matching section.

#### `radin-setup-hooks`

Wire up per-repo config for companion tools — currently just
`code-review-graph`'s MCP registration and hooks.

```
/radin-setup-hooks
```

Run this once per project, right after `install.sh`, in the repo you want
wired. It previews the exact files it will touch and asks for confirmation
before writing anything.

### Vendored in *(optional)*

`install.sh` just asks if you want them — never forked, never vendored,
their own repo stays the source of truth.

| Tool | What it does |
| --- | --- |
| [rtk](https://github.com/rtk-ai/rtk) | CLI proxy that reduces LLM token consumption by 60-90% on common dev commands. Single Rust binary, zero dependencies |
| [caveman](https://github.com/JuliusBrussee/caveman) | Why use many token when few token do trick — Claude Code skill that cuts 65% of tokens by talking like caveman |
| [i-have-adhd](https://github.com/ayghri/i-have-adhd) | A skill for your coding agent to stop it from burying the answer. ADHD-friendly output |
| [ponytail](https://github.com/DietrichGebert/ponytail) | Makes your AI agent think like the laziest senior dev in the room. The best code is the code you never wrote |
| [code-review-graph](https://github.com/tirth8205/code-review-graph) | Local-first code intelligence graph for MCP and CLI. Builds a persistent map of your codebase so AI coding tools read only what matters |
| [thermo-nuclear](https://github.com/cursor/plugins/tree/main/cursor-team-kit/skills/thermo-nuclear-code-quality-review) | Code quality review skill, vendored from cursor/plugins at install time via the [vercel-labs/skills](https://github.com/vercel-labs/skills) CLI |

---

Maintaining or hacking on radin itself? See [AGENTS.md](AGENTS.md) and
[CONTRIBUTING.md](CONTRIBUTING.md).
