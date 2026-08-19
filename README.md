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

Opinionated agentic stack, one script deep, bakes in most efficient (and safe) token-reduction tools around.

## Install

### Requirements

radin itself only copy files. Companion tools pull own stacks, each gated behind explicit pick in arrow-key prompt.

| For | You need |
| --- | --- |
| radin core (agents + skills) | `curl`, `tar`, `bash` |
| Claude plugins (caveman, ponytail) | `claude` CLI |
| rtk | [Homebrew](https://brew.sh), or `curl` for rtk's own installer |
| code-review-graph, headroom | `python3` with `pip3` or [`pipx`](https://pipx.pypa.io) |

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

## Update

```sh
# macOS · Linux · WSL
curl -fsSL https://raw.githubusercontent.com/shortcuts/radin/main/install.sh | bash -s -- --force
```

## The backlog lifecycle

Repo's backlog live inside repo, at `.claude/.radin/backlog/`
from repo root: index file plus one markdown file per task. Every
radin tool read from or write to it through radin's own CLI, never need look inside. Run `/radin-show` read it as plain markdown.
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
4. **Review.** Run `radin-review` against commit, PR, or directory. Every
   finding become new backlog entry, ready for next pass of step 3.

## Tools you get

### Homemade

| Tool | What it does |
| --- | --- |
| `radin-execute` | Chews through backlog, one task at time, commits as it goes |
| `radin-plan` | Writes plan for one backlog entry you point it at, instead of touching code |
| `radin-review` | Strict code-quality pass, findings logged straight back into backlog |
| `radin-record` | Logs feedback/bugs/ideas raised mid-session as backlog entries |
| `radin-show` | Prints current project's backlog |
| `radin-doctor` | Checks radin's own install complete, reports which companion tools reachable |
| `radin-setup-hooks` | Wires up per-repo hooks/MCP config for companion tools |
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
Finished entries removed from backlog; failed ones stay, marked
for retry. At end can optionally run `/thermo-nuclear` review of
session, log findings back to backlog as new entries.

#### `radin-review`

Run strict quality review over chosen scope, log findings to
backlog instead of printing to terminal.

```
/radin-review #123
```

Also accepts commit hash, directory path, or natural-language range
like `"commits since Monday"`. Result: one backlog task per finding,
classified as `fix` (real bug) or `refactor` (structural).

#### `radin-setup-hooks`

Wire up per-repo config for companion tools — currently just
`code-review-graph`'s MCP registration and hooks.

```
/radin-setup-hooks
```

Run once per project, right after `install.sh`, in repo you want
wired. Previews exact files it will touch, asks confirmation
before writing anything.

### Vendored in *(optional)*

`install.sh` just asks if you want them — never forked, never vendored,
own repo stays source of truth.

| Tool | What it does |
| --- | --- |
| [rtk](https://github.com/rtk-ai/rtk) | CLI proxy reduces LLM token consumption 60-90% on common dev commands. Single Rust binary, zero dependencies |
| [caveman](https://github.com/JuliusBrussee/caveman) | Why use many token when few token do trick — Claude Code skill cuts 65% of tokens by talking like caveman |
| [ponytail](https://github.com/DietrichGebert/ponytail) | Makes AI agent think like laziest senior dev in room. Best code is code never written |
| [code-review-graph](https://github.com/tirth8205/code-review-graph) | Local-first code intelligence graph for MCP and CLI. Builds persistent map of codebase so AI coding tools read only what matters |
| [headroom](https://github.com/headroomlabs-ai/headroom) | Local-first context-compression stack — proxy/MCP/wrap layer with cross-agent memory and CLAUDE.md-learning. Complements rtk (whole-session wrap vs. rtk's per-command compression), not replacement. Python/pip footprint — install prompts extra confirmation |
| [thermo-nuclear](https://github.com/cursor/plugins/tree/main/cursor-team-kit/skills/thermo-nuclear-code-quality-review) | Code quality review skill, vendored from cursor/plugins at install time via [vercel-labs/skills](https://github.com/vercel-labs/skills) CLI |
| [mattpocock-skills](https://github.com/mattpocock/skills) | Engineering skills plugin (`claude-plugins-official` marketplace) — `radin-plan` delegates interview step to `/grilling`, API/library fact-checking to `/research` instead of reimplementing them |

---

Maintaining or hacking on radin itself? See [AGENTS.md](AGENTS.md) and
[CONTRIBUTING.md](CONTRIBUTING.md).
