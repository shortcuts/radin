<p align="center">
  <strong>🐀 radin</strong> — stingy on tokens, generous on backlog throughput
</p>

<p align="center">
  <sub><em>Fun fact: "radin" is French slang for a miser — someone tight with their money is often called "un rat" ("a rat"). Hence the mascot.</em></sub>
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue?style=flat" alt="License"></a>
  <a href="AGENTS.md"><img src="https://img.shields.io/badge/platform-macOS%20%7C%20Linux-lightgrey?style=flat" alt="macOS | Linux"></a>
  <a href="CHANGELOG.md"><img src="https://img.shields.io/badge/status-scaffold-orange?style=flat" alt="Status: scaffold"></a>
</p>

<p align="center">
  <a href="#quickstart">Quickstart</a> ·
  <a href="#tools-you-get">Tools you get</a> ·
  <a href="#whats-here">What's here</a> ·
  <a href="#storage-model">Storage model</a> ·
  <a href="#companion-tools-installed-separately-not-vendored">Companion tools</a>
</p>

---

One install for solo devs on a small Claude subscription: backlog-driven
execution (`radin-orchestrator`, `radin-plan`, `radin-review`) plus one-prompt
installs for a curated set of companion OSS tools. radin doesn't do cost
optimization itself — it wires up and orchestrates tools that already do
(rtk, caveman) via their own install paths, never vendored or forked, so
they get the credit and the updates.

## Tools you get

| Tool | What it does |
| --- | --- |
| `radin-orchestrator` | Works through your `ISSUES.md` backlog, one task at a time, committing as it goes |
| `radin-plan` | Same backlog, but writes a plan per task instead of executing |
| `radin-review` | Runs a strict code-quality pass and logs findings back into the backlog |
| [rtk](https://github.com/rtk-ai/rtk) *(optional)* | Token-cheap CLI proxy |
| [caveman](https://github.com/JuliusBrussee/caveman) *(optional)* | Ultra-compressed agent output |
| [i-have-adhd](https://github.com/ayghri/i-have-adhd) *(optional)* | ADHD-friendly output shaping (action-first, numbered steps) |
| [ponytail](https://github.com/DietrichGebert/ponytail) *(optional)* | "Lazy senior dev" ruleset — pushes agents to skip unnecessary code, reuse what's already there |
| [code-review-graph](https://github.com/tirth8205/code-review-graph) *(optional)* | Knowledge-graph-backed code review MCP |

The first three are radin's own, shipped in this repo. The rest are other
people's tools — `install.sh` offers to install them, nothing more.

## Quickstart

```sh
# macOS · Linux · WSL
curl -fsSL https://raw.githubusercontent.com/shortcuts/radin/main/install.sh | bash
```

Requires [Homebrew](https://brew.sh), `curl`, and `tar` — no `git clone`
needed. Downloads the latest published release from GitHub (falling back to
`main` if none exists yet) into `~/.claude/radin` (override with
`RADIN_ROOT_OVERRIDE=<path>`), re-downloading fresh on every subsequent
install. Every companion-tool install is a per-tool `y`/`N` prompt — nothing
installs silently. Companion tools already detected on your system are
skipped by default; pass `--force` to re-prompt for all of them and decide
per-tool what to (re)install/update:

```sh
curl -fsSL https://raw.githubusercontent.com/shortcuts/radin/main/install.sh | bash -s -- --force
```

Prefer a manual clone (e.g. to hack on radin itself)?

```sh
git clone https://github.com/shortcuts/radin ~/Documents/radin
cd ~/Documents/radin
./install.sh
```

`install.sh` detects it's running from a real checkout (sibling
`agents/`/`skills/` dirs) and uses that in place of cloning.

## What's here

| | |
| --- | --- |
| `agents/radin-orchestrator.md` | Works through an `ISSUES.md` backlog one task at a time, delegating implementation to sub-agents and committing after each task. |
| `agents/radin-plan.md` | Same prioritization as `radin-orchestrator`, but writes one implementation plan per task instead of executing. |
| `skills/radin-review/` | Runs a thermo-nuclear code quality review and logs findings as structured backlog entries instead of only printing them. |
| `thermo-nuclear` (downloaded, not shipped) | The strict maintainability review itself — invoked by `radin-review` and by `radin-orchestrator`'s optional Phase 5 review step. `install.sh` downloads its `SKILL.md` straight from cursor/plugins' [`thermo-nuclear-code-quality-review`](https://github.com/cursor/plugins/blob/main/cursor-team-kit/skills/thermo-nuclear-code-quality-review/SKILL.md) at install time — not vendored, not radin-original. |
| `skills/radin-setup-hooks/` | Wires a companion tool's per-repo MCP/hook config (currently `code-review-graph`) into whatever repo you invoke it from — `install.sh` only installs the binary globally. |
| `skills/radin-update/` | Pulls the latest radin commits and re-runs `install.sh` to refresh `~/.claude/agents/`/`~/.claude/skills/`. |
| `install.sh` | Installs radin's agents/skills into `~/.claude/`, offers the companion tools below. |

## Storage model

Backlog content and execution state never land in a target repo — they live
in a canonical namespace under `~/.claude/.radin/projects/<repo-slug>/`. See
[docs/architecture.md](docs/architecture.md) for the full layout and
[docs/domain-models.md](docs/domain-models.md) for file formats.

## Companion tools (installed separately, not vendored)

| Tool | Role |
| --- | --- |
| [rtk](https://github.com/rtk-ai/rtk) | Token-cheap CLI proxy — cost optimization |
| [caveman](https://github.com/JuliusBrussee/caveman) | Ultra-compressed agent output mode — cost optimization |
| [i-have-adhd](https://github.com/ayghri/i-have-adhd) | ADHD-friendly output shaping — action-first, numbered steps, no preamble |
| [ponytail](https://github.com/DietrichGebert/ponytail) | "Lazy senior dev" ruleset — cost/effort optimization by minimizing unnecessary code |
| [code-review-graph](https://github.com/tirth8205/code-review-graph) | Knowledge-graph-backed code review MCP |

`caveman`, `i-have-adhd`, and `ponytail` all install as Claude Code plugins
(`claude plugin marketplace add` + `claude plugin install`) — their hooks/
output-style register globally at install time, no further setup needed.
`rtk` installs via Homebrew. `code-review-graph`
installs via `pipx`/`pip` (it's a PyPI package, not npm); `install.sh` only
installs the binary — its MCP server and hooks are repo-scoped, so run the
`radin-setup-hooks` skill from inside each project you want it wired into.
