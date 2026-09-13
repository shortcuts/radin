<p align="center">
  <strong>🐀 radin</strong>
</p>

<p align="center">
  <em>Too cheap pay full price whole AI tool stack — so went shopping for you.</em>
</p>

<p align="center">
  <sub>"Radin" French slang for miser. Hence rat.</sub>
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

## What is radin

radin is a Claude Code plugin for the solo dev on a small Claude
subscription. One `curl | bash` installs two things:

1. **A backlog-driven workflow.** Skills that record tasks as files in your
   repo, plan them, execute them one commit at a time, and review the result.
   Every task survives past the conversation, every run resumes where it
   stopped.
2. **A curated set of token-reduction tools.** rtk, caveman, ponytail,
   codebase-memory-mcp, headroom — each optional, each installed only on your
   explicit yes, each its own project. radin never forks or vendors them; it
   shops.

The goal: stretch a small subscription further. Fewer tokens per task, and
agent runs that are resumable and verifiable instead of fire-and-forget.

## Install

### Requirements

radin itself only copy files. Companion tools pull own stacks, each gated behind explicit pick in arrow-key prompt — or all of them at once with `--yes`.

| For | You need |
| --- | --- |
| radin core (skills) | `curl`, `tar`, `bash` |
| Claude plugins (caveman, ponytail) | `claude` CLI |
| rtk | [Homebrew](https://brew.sh), or `curl` for rtk's own installer |
| codebase-memory-mcp | `curl` for its own installer (static binary, no runtime). `python3` to bracket its `~/.claude` write — without it, radin installs binary only |
| headroom | `python3` with `pip3` or [`pipx`](https://pipx.pypa.io) |

Homebrew optional. When present, radin use it for `rtk`. Not required on Linux.

> **Homebrew Python note (macOS).** Broken `python@3.14` bottle can make
> every `pip`/`pipx` install fail with `pyexpat` / `libexpat` symbol error.
> `install.sh` detect this, print fix: `brew reinstall
> --build-from-source python@3.14`. Plain `brew reinstall` reinstall
> same broken bottle — `--build-from-source` flag relinks Python
> against Homebrew's `expat`.

```sh
# macOS · Linux · WSL
curl -fsSL https://raw.githubusercontent.com/shortcuts/radin/main/install.sh | bash
```

Same stack on next machine, no questions: add `--yes`. Every companion tool
installs, plus radin's guidance block in `~/.claude/CLAUDE.md` (between
`radin:begin`/`radin:end` markers). Behaviour answers — concurrency, refuter
pass, sub-agent models — keep their defaults.

```sh
curl -fsSL https://raw.githubusercontent.com/shortcuts/radin/main/install.sh | bash -s -- --yes
```

## Update

`--force` also updates companion tools already installed.

```sh
# macOS · Linux · WSL
curl -fsSL https://raw.githubusercontent.com/shortcuts/radin/main/install.sh | bash -s -- --force
```

## The backlog lifecycle

Repo's backlog live inside repo, at `.claude/.radin/backlog/`
from repo root: index file plus one markdown file per task. Every
radin tool read from or write to it through radin's own CLI (`radin backlog`, `radin state`, ... — symlinked into `~/.local/bin` at install), never need look inside. Run `/radin-show` read it as plain markdown.
Commit `.claude/.radin/` share backlog with team, or add to
`.gitignore` keep private. Radin never touch your `.gitignore`
either way.

Typical flow:

1. **Capture.** Something come up mid-session — bug, idea, feedback
   from teammate. Run `radin-record` turn it into backlog entry.
2. **Plan (optional).** Point `radin-plan` at one entry write
   step-by-step plan for it, without touching any code. Repeat per entry you
   want planned ahead of time.
3. **Execute.** Run `radin-execute` work through backlog,
   entry by entry, committing as it goes.
4. **Review.** Run `radin-review` against commit, PR, or directory. It shows
   findings, asks which to keep, then each kept one become new backlog entry,
   ready for next pass of step 3.

## Tools you get

### Homemade

| Tool | What it does |
| --- | --- |
| `radin-execute` | Chews through backlog, one task at time, commits as it goes |
| `radin-plan` | Writes plan for one backlog entry you point it at, instead of touching code |
| `radin-review` | Strict code-quality pass, findings triaged with you then logged into backlog |
| `radin-record` | Logs feedback/bugs/ideas raised mid-session as backlog entries |
| `radin-show` | Prints current project's backlog |
| `radin-doctor` | Checks radin's own install complete, reports which companion tools reachable |
| `radin-setup-hooks` | Fallback per-repo wiring for codebase-memory-mcp, when `install.sh` could not wire it globally |
| `radin-stats` | Shows each installed companion tool's own stats/gain output, side by side |
| `radin-uninstall` | Removes everything `install.sh` added to `~/.claude` |

Some delegate to other skills instead of reimplementing review or
style logic themselves:

| Tool | Delegates to |
| --- | --- |
| `radin-execute` | `/ponytail` (plan-or-skip gate, per-task implementation), `/radin-plan` (only for tasks judged complex enough), `/caveman-commit` (commit message), `/radin-review` (optional end-of-session review) |
| `radin-plan` | `/ponytail` (split judgment and plan writing), `/thermo-nuclear` + `/ponytail-review` (reviewing plan itself before handoff) |
| `radin-review` | `/thermo-nuclear` (code-quality pass), `/ponytail-review` or `/ponytail-audit` (over-engineering pass) |

#### `radin-record`

Log something raised mid-conversation, before lost.

```
/radin-record log the auth timeout bug we just found
```

Result: new `fix`-classified task added to backlog, bug
described enough detail future session act on it, no other
context needed.

#### `radin-plan`

Write plan for one backlog entry, without writing any code. Judges
whether entry's scope should split into multiple independent plans,
confirms with you before splitting.

```
/radin-plan the auth timeout bug
```

Result: one plan file per plan under `.claude/.radin/plans/` at repo
root (more than one if entry split). Each plan reviewed with
`/thermo-nuclear` and `/ponytail-review` before handoff, findings
fixed directly in plan file, `**Plan:** <path>` line appended to
task's own backlog file per plan produced.

#### `radin-execute`

Work through backlog end to end: prioritize, implement, test, commit —
one entry at time. Uses existing plan from `radin-plan` if entry
already has one. If not, asks `/ponytail` whether task straightforward
enough implement directly. Only tasks judged genuinely
complex go through `/radin-plan` first.

```
/radin-execute
```

Result: each entry implemented and committed in its own commit.

Runs in your own conversation, so it asks you to confirm the execution order
before it starts, and you can interrupt it. Every task's state is on disk, so
re-running `/radin-execute` resumes where it stopped and never redoes finished
work.

Want your thread free while the backlog runs? Two ways:

- **`claude agents`** — dispatch `/radin-execute` as a background session,
  then peek, reply, or attach whenever you like. Each one is a full Claude
  Code conversation, so nothing about the skill changes. `/bg` sends the
  conversation you're already in over there instead.
- **A second `claude` session** in another terminal. Same thing, one window
  per run.

Either way the worktree-per-task answer keeps concurrent runs off each
other's checkout.
Finished entries removed from backlog; failed ones stay, marked
for retry. At end can optionally run `/thermo-nuclear` review of
session, log findings back to backlog as new entries.

#### `radin-review`

Run strict quality review over chosen scope, then log findings to
backlog instead of printing to terminal. Nothing logged without your
agreement: skill lists findings, asks which to keep (its picks, all, or
yours), then offers refinement pass that grills each kept finding via
`/mattpocock-skills:grilling` before write.

```
/radin-review #123
```

Also accepts commit hash, directory path, or natural-language range
like `"commits since Monday"`. Result: one backlog task per kept finding,
classified as `fix` (real bug) or `refactor` (structural).

#### `radin-setup-hooks`

Wire codebase-memory-mcp into Claude Code: graph section in
`~/.claude/CLAUDE.md`, MCP server entry in repo's `.mcp.json`. No hook —
codebase-memory-mcp's own background watcher keeps graph current, and
`install.sh` turns on `auto_index` so first connection indexes project.

```
/radin-setup-hooks
```

Run once per project, right after `install.sh`, in repo you want wired.
Names exact writes, asks confirmation first. radin's own script merge-only:
anything already defined never redefined.

Most installs need no `/radin-setup-hooks` at all: one yes to
codebase-memory-mcp installs whole tool — its skill, three graph agents, hooks
that route Grep/Glob to graph, and user-scope MCP entry that makes every repo
work with no per-project step. radin wraps that write (`radin cbm-config
install`) because upstream
[#1200](https://github.com/DeusData/codebase-memory-mcp/issues/1200) replaces
whole `SessionStart` array in `~/.claude/settings.json` instead of merging,
which drops caveman's and ponytail's own hooks: radin snapshots
`settings.json` + `~/.claude.json` into `~/.claude/.radin/backups/` first,
runs their installer, then puts back every entry that write dropped. Prints
one `RESTORED`/`INTACT` line each. After `codebase-memory-mcp update` reruns
same write, run `radin cbm-config repair`.

Run `/radin-setup-hooks` only when `python3` was missing at install time (radin
then skips upstream's config, since it cannot restore afterwards) or when you
uninstalled upstream's side but kept radin.

### Vendored in *(optional)*

`install.sh` just asks if you want them — never forked, never vendored,
own repo stays source of truth.

| Tool | What it does |
| --- | --- |
| [rtk](https://github.com/rtk-ai/rtk) | CLI proxy reduces LLM token consumption 60-90% on common dev commands. Single Rust binary, zero dependencies |
| [caveman](https://github.com/JuliusBrussee/caveman) | Why use many token when few token do trick — Claude Code skill cuts 65% of tokens by talking like caveman |
| [ponytail](https://github.com/DietrichGebert/ponytail) | Makes AI agent think like laziest senior dev in room. Best code is code never written |
| [codebase-memory-mcp](https://github.com/DeusData/codebase-memory-mcp) | Code intelligence MCP server. Indexes repo into persistent knowledge graph (158 tree-sitter grammars, sub-ms queries) so agent asks graph instead of grepping files. Single static binary, no runtime. Installed with `--skip-config` — radin owns every `~/.claude` write |
| [headroom](https://github.com/headroomlabs-ai/headroom) | Local-first context-compression stack — proxy/MCP/wrap layer with cross-agent memory and CLAUDE.md-learning. Complements rtk (whole-session wrap vs. rtk's per-command compression), not replacement. Python/pip footprint — install prompts extra confirmation |
| [thermo-nuclear](https://github.com/cursor/plugins/tree/main/cursor-team-kit/skills/thermo-nuclear-code-quality-review) | Code quality review skill, vendored from cursor/plugins at install time via [vercel-labs/skills](https://github.com/vercel-labs/skills) CLI |
| [mattpocock-skills](https://github.com/mattpocock/skills) | Engineering skills plugin (`claude-plugins-official` marketplace) — `radin-plan` and `radin-review` delegate interview step to `/grilling`, `radin-plan` sends API/library fact-checking to `/research` instead of reimplementing them |

---

Maintaining or hacking on radin itself? See [AGENTS.md](AGENTS.md) and
[CONTRIBUTING.md](CONTRIBUTING.md).
