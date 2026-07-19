<p align="center">
  <strong>radin</strong> — stingy on tokens, generous on backlog throughput
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue?style=flat" alt="License"></a>
  <a href="AGENTS.md"><img src="https://img.shields.io/badge/platform-macOS%20%7C%20Linux-lightgrey?style=flat" alt="macOS | Linux"></a>
  <a href="CHANGELOG.md"><img src="https://img.shields.io/badge/status-scaffold-orange?style=flat" alt="Status: scaffold"></a>
</p>

<p align="center">
  <a href="#quickstart">Quickstart</a> ·
  <a href="#whats-here">What's here</a> ·
  <a href="#storage-model">Storage model</a> ·
  <a href="#companion-tools-installed-separately-not-vendored">Companion tools</a>
</p>

---

Cost-optimized agentic workflow stack for solo devs on a small Claude
subscription. One install gives backlog-driven execution
(`radin-orchestrator`, `radin-plan`, `radin-review`) plus offers of
a curated set of companion OSS tools — installed via their own existing
install paths, never vendored or forked.

## Quickstart

```sh
# macOS · Linux · WSL · Git Bash
curl -fsSL https://raw.githubusercontent.com/shortcuts/radin/main/install.sh | bash
```

Requires [Homebrew](https://brew.sh) and `git`. Clones radin to
`~/.claude/radin` (override with `RADIN_ROOT_OVERRIDE=<path>`) and re-runs
`git pull` there on subsequent installs. Every companion-tool install is a
per-tool `y`/`N` prompt — nothing installs silently.

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
|---|---|
| `agents/radin-orchestrator.md` | Works through an `ISSUES.md` backlog one task at a time, delegating implementation to sub-agents and committing after each task. |
| `agents/radin-plan.md` | Same prioritization as `radin-orchestrator`, but writes one implementation plan per task instead of executing. |
| `skills/radin-review/` | Runs a thermo-nuclear code quality review and logs findings as structured backlog entries instead of only printing them. |
| `skills/thermo-nuclear/` | The strict maintainability review itself — invoked by `radin-review` and by `radin-orchestrator`'s optional Phase 5 review step. Vendored verbatim from cursor/plugins' [`thermo-nuclear-code-quality-review`](https://github.com/cursor/plugins/blob/main/cursor-team-kit/skills/thermo-nuclear-code-quality-review/SKILL.md) — not radin-original. |
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
|---|---|
| [rtk](https://github.com/rtk-ai/rtk) | Token-cheap CLI proxy — cost optimization |
| [caveman](https://github.com/JuliusBrussee/caveman) | Ultra-compressed agent output mode — cost optimization |
| [code-review-graph](https://github.com/tirth8205/code-review-graph) | Knowledge-graph-backed code review MCP |

`caveman` installs as a Claude Code plugin (`claude plugin marketplace add` +
`claude plugin install`) — its hooks register globally at install time, no
further setup needed. `rtk` installs via Homebrew. `code-review-graph`
installs via `pipx`/`pip` (it's a PyPI package, not npm); `install.sh` only
installs the binary — its MCP server and hooks are repo-scoped, so run the
`radin-setup-hooks` skill from inside each project you want it wired into.
