<p align="center">
  <strong>🐀 radin</strong>
</p>

<p align="center">
  <em>A backlog and an agent harness for people who watch their token bill.</em>
</p>

<p align="center">
  <sub>"Radin" is French slang for a miser. Hence the rat.</sub>
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue?style=flat" alt="License"></a>
  <a href="docs/install.md"><img src="https://img.shields.io/badge/platform-macOS%20%7C%20Linux-lightgrey?style=flat" alt="macOS | Linux"></a>
</p>

<p align="center">
  <img src="docs/img/tui.svg" alt="The radin TUI: a backlog of two epics and nine tasks, with a detail pane" width="860">
</p>

Your subscription has a limit. A long agent session hits it by Tuesday.
radin is for the person who would rather ship than upgrade the plan.

It works with Claude Code, Codex CLI and opencode. It has two parts.

1. **A backlog that outlives the conversation.** Tasks and epics are files in your repo.
   You record a bug or an idea mid-session and come back to it later.
2. **A harness that works the backlog cheaply.** A small router plans a task, hands it to a fresh
   sub-agent, reviews the diff, and commits. One task, one commit. A run resumes where it stopped.

The harness keeps the expensive context small. A stack of token-saving tools handles the rest.
radin installs that stack and wires it into your host.

## Why it costs less

- The router holds ids and exit codes. It never reads your code.
- Each sub-agent starts empty and sees one task. No context carries over from task to task.
- Ordering, status and merging run in a CLI. No model call pays for them.
- The cheaper model runs fact-finding only. Every execution task runs on sonnet.
- [rtk](https://github.com/rtk-ai/rtk) and [caveman](https://github.com/JuliusBrussee/caveman) cut command output and agent prose.
  Their figures are in [the tool stack](#the-tool-stack). They are upstream's claims, not ours.

Run `/radin-stats` to see what each tool saved on your machine.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/shortcuts/radin/main/install.sh | bash
```

You need `curl`, `tar`, `bash` and the CLI of each host you pick. Add `-s -- --yes` to accept every default.
Update, repair and uninstall: [docs/install.md](docs/install.md).

Pick hosts with `--only`. Each row installs one host:

| Host | Install command | What auto-activates |
| --- | --- | --- |
| Claude Code | `curl -fsSL <url> \| bash -s -- --only claude` | Skills in `~/.claude/skills`. A radin block in `~/.claude/CLAUDE.md`. Companion hooks in `~/.claude/settings.json` |
| Codex CLI | `curl -fsSL <url> \| bash -s -- --only codex` | Skills in `~/.agents/skills`. A radin block in `$CODEX_HOME/AGENTS.md`. Hooks run after you trust them in `/hooks` |
| opencode | `curl -fsSL <url> \| bash -s -- --only opencode` | Skills in `~/.agents/skills`. A radin block in `~/.config/opencode/AGENTS.md`. Seven `radin-<kind>.md` agents. An allow rule for `~/.radin/**` |

`<url>` is the `install.sh` URL in the first command. Pass a comma list to install several hosts: `--only claude,codex`.

| Flag | What it does |
| --- | --- |
| `--only ID[,ID...]` | Installs the listed hosts. IDs: `claude`, `codex`, `opencode` |
| `--list` | Prints each host ID, its label and whether it is detected. Changes nothing |
| `--dry-run` | Prints every write and command. Writes nothing |
| `--force` | Moves a conflicting file to `~/.radin/backups/` and installs radin's file |
| `--yes` | Accepts every default |

Without `--only`, a terminal runs a step-by-step wizard (hosts as a checkbox list, models, package manager) and Left or Backspace goes back one step. `claude` starts ticked.
Without a terminal, the installer installs `claude` only.

Per-host details: [Codex](docs/hosts/codex.md), [opencode](docs/hosts/opencode.md).

**Claude migration:** the first install after this change moves `~/.claude/.radin` to `~/.radin`.
Restart open Claude sessions.

## Use it

Record, plan, execute, review. Each skill runs in your own conversation, so it can ask you questions.

| Command | What it does |
| --- | --- |
| `/radin-record` | Turn a bug, idea or aside from this session into a backlog task |
| `/radin-plan` | Write a step-by-step plan for one task. Touches no code |
| `/radin-batch` | Work the backlog in priority order. One task per commit |
| `/radin-do` | Record one ad-hoc prompt as a task, then execute only that task |
| `/radin-review` | Review a commit, PR or directory. Kept findings go to the backlog |
| `/radin-stats` | Show every companion tool's savings report |
| `/radin-teardown` | Gracefully stop a running batch: finish the current task, gate and merge, start nothing new |
| `/radin-uninstall` | Remove what the installer put in every host's skills dir |
| `radin` | Full-screen backlog browser in your terminal. Press `?` for keys |
| `radin --host agents ...` | Same command for the agents host, which spells companion skill names for Codex and opencode. The backlog is the same `.radin` |

`install.sh --wave-cap N` sets the most tasks `/radin-batch` runs at once (default 2, kept by `radin update`). `RADIN_WAVE_CAP` overrides it for one run. Parallel work needs the worktree answer yes.

A task has a category (`feat`, `fix`, `chore`, `refactor`), an optional priority and
dependencies, and can sit under an epic. Every field and key: [docs/reference.md](docs/reference.md).

## The harness

`/radin-batch` and `/radin-do` run the same loop. It follows the orchestrator-workers pattern:
a thin router drives, and sub-agents work.

- **A small router.** It holds ids, titles and exit codes. A worker reads the task, the plan and the code,
  then returns one `STATUS:` line.
- **One worker, one task.** Each worker starts with an empty context and sees only what its task needs.
- **A verify loop.** The worker checks its own diff and retries a failed check three times.
  One review gate at the end of the session reviews every commit and files its findings as new tasks.
- **Just-in-time plans.** radin lints each plan and writes it against the tree as it is now.
- **Model by role.** The cheaper model runs fact-finding only. Every execution task runs on sonnet.
- **State on disk.** Interrupt a run at any point and the next run picks up from there.
- **The CLI does the deterministic work.** Ordering, status and merging are code, not prompts.

Why it works this way: [docs/how-it-works.md](docs/how-it-works.md).
Diagrams: [docs/agents/lifecycle.md](docs/agents/lifecycle.md).

## The tool stack

radin does not rebuild what a good tool already does. It installs each tool below,
configures it, and names it in the loop. It forks none of them.

| Tool | Job in the loop |
| --- | --- |
| [rtk](https://github.com/rtk-ai/rtk) | Wraps dev commands and cuts their output by 60-90% (upstream's figure) |
| [caveman](https://github.com/JuliusBrussee/caveman) | Terse agent prose, about 65% fewer output tokens (upstream's figure) |
| [ponytail](https://github.com/DietrichGebert/ponytail) | Makes the agent write the smallest change that works |
| [codebase-memory-mcp](https://github.com/DeusData/codebase-memory-mcp) | Indexes the repo into a graph, so the agent asks instead of grepping |
| [thermo-nuclear](https://github.com/cursor/plugins/tree/main/cursor-team-kit/skills/thermo-nuclear-code-quality-review) | Strict maintainability review |
| [mattpocock-skills](https://github.com/mattpocock/skills) | Interviewing, research, diagnosis and design skills |
| [unslop](https://github.com/cursor/plugins/tree/main/pstack/skills/unslop) | Strips AI-slop patterns from prose |
| [technical-writing](https://github.com/cursor/plugins/tree/main/pstack/skills/technical-writing) | Writing rules for docs and agent-facing prose |

Run `/radin-stats` to see what each one saved on your machine.
Caveats on unpinned fetches and config repair: [docs/how-it-works.md](docs/how-it-works.md#trade-offs-to-know).

## Documentation

| You want to | Read |
| --- | --- |
| Try radin step by step | [Tutorial](docs/tutorial.md) |
| Install, update or uninstall | [Install guide](docs/install.md) |
| Set up Codex or opencode | [Codex](docs/hosts/codex.md), [opencode](docs/hosts/opencode.md) |
| Do one specific thing | [How-to guides](docs/guides.md) |
| Look up a command, field or key | [Reference](docs/reference.md) |
| Understand the design | [How radin works](docs/how-it-works.md), [lifecycle diagrams](docs/agents/lifecycle.md), [decisions](docs/agents/DECISIONS.md) |

## Contribute

[CONTRIBUTING.md](CONTRIBUTING.md) covers tests and measurements.

## For agents

[AGENTS.md](AGENTS.md) holds the rules for agents that edit this repo.
Design rules and flow diagrams live in [docs/agents/](docs/agents/).
Human docs stay in [docs/](docs/).
