#!/usr/bin/env bash
set -euo pipefail

# Colors -- disabled when stdout isn't a terminal (piped/redirected/CI).
if [ -t 1 ]; then
	BOLD='\033[1m'
	DIM='\033[2m'
	RED='\033[31m'
	GREEN='\033[32m'
	YELLOW='\033[33m'
	MAGENTA='\033[35m'
	CYAN='\033[36m'
	RESET='\033[0m'
else
	BOLD=''
	DIM=''
	RED=''
	GREEN=''
	YELLOW=''
	MAGENTA=''
	CYAN=''
	RESET=''
fi

FORCE=""
YES=""
for arg in "$@"; do
	[ "$arg" = "--force" ] && FORCE="1"
	[ "$arg" = "--yes" ] && YES="1"
done

RAT='🐀'
info() { printf "%b\n" "${CYAN}${RAT}${RESET} $*"; }
ok() { printf "%b\n" "${GREEN}${RAT}${RESET} $*"; }
warn() { printf "%b\n" "${YELLOW}${RAT}${RESET} $*"; }
step() { printf "\n%b\n" "${BOLD}${MAGENTA}${RAT} $*${RESET}"; }

printf "%b\n" "${BOLD}${MAGENTA}"
printf "%s\n" "  🐀 radin — stingy on tokens, generous on backlog throughput"
printf "%b\n\n" "${RESET}"

BREW="$(command -v brew || true)"
[ -n "$BREW" ] && eval "$("$BREW" shellenv)"

GITHUB_REPO="shortcuts/radin"
API_LATEST_RELEASE="https://api.github.com/repos/$GITHUB_REPO/releases/latest"
TARBALL_BASE="https://github.com/$GITHUB_REPO/archive"
DEFAULT_FETCH_DIR="$HOME/.claude/radin"

# Resolve RADIN_ROOT from the running script's own location -- works when
# executed from a real git clone (./install.sh), for hacking on radin itself.
# Piped via curl | bash, BASH_SOURCE[0] has no usable sibling agents/skills
# dirs, so this returns empty and the block below downloads a source tarball
# instead -- no git clone, no local git dependency.
resolve_radin_root() {
	local script_path="${BASH_SOURCE[0]}"
	if [ -f "$script_path" ]; then
		local dir
		dir="$(cd "$(dirname "$script_path")" && pwd)"
		if [ -d "$dir/agents" ] && [ -d "$dir/skills" ]; then
			printf '%s' "$dir"
			return
		fi
	fi
	printf '%s' ""
}

step "Resolving radin source"
RADIN_ROOT="$(resolve_radin_root)"
if [ -z "$RADIN_ROOT" ]; then
	command -v curl >/dev/null 2>&1 || {
		printf "%b\n" "${RED}${RAT} curl not found.${RESET} Install curl, then re-run." >&2
		exit 1
	}
	command -v tar >/dev/null 2>&1 || {
		printf "%b\n" "${RED}${RAT} tar not found.${RESET} Install tar, then re-run." >&2
		exit 1
	}

	FETCH_DIR="${RADIN_ROOT_OVERRIDE:-$DEFAULT_FETCH_DIR}"
	if [ -d "$FETCH_DIR" ] && [ ! -f "$FETCH_DIR/.radin-version" ]; then
		printf "%b\n" "${RED}${RAT} $FETCH_DIR exists and wasn't created by this installer${RESET} -- remove it or set RADIN_ROOT_OVERRIDE to a different path, then re-run." >&2
		exit 1
	fi

	# Redirect lookup first -- doesn't count against the API's 60 req/hour
	# anonymous rate limit. Fall back to the API only if that fails.
	VERSION="$(curl -sI "https://github.com/$GITHUB_REPO/releases/latest" 2>/dev/null | grep -i '^location:' | sed -E 's|.*/tag/([^[:space:]]+).*|\1|' | tr -d '\r')"
	if [ -z "$VERSION" ]; then
		VERSION="$(curl -fsSL "$API_LATEST_RELEASE" 2>/dev/null | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')"
	fi
	if [ -n "$VERSION" ]; then
		info "Latest release: ${BOLD}$VERSION${RESET}"
		TARBALL_URL="$TARBALL_BASE/refs/tags/$VERSION.tar.gz"
	else
		VERSION="main"
		info "No published release found, using ${BOLD}main${RESET}"
		TARBALL_URL="$TARBALL_BASE/refs/heads/main.tar.gz"
	fi

	info "Downloading radin ($VERSION)..."
	TMP_TAR="$(mktemp)"
	curl -fsSL "$TARBALL_URL" -o "$TMP_TAR"
	# Reject archives with absolute paths or ".." components before extracting (CWE-22).
	if tar -tzf "$TMP_TAR" | grep -qE '^/|(^|/)\.\.(/|$)'; then
		printf "%b\n" "${RED}${RAT} Downloaded archive contains unsafe paths.${RESET} Refusing to extract." >&2
		rm -f "$TMP_TAR"
		exit 1
	fi
	rm -rf "$FETCH_DIR"
	mkdir -p "$FETCH_DIR"
	tar -xzf "$TMP_TAR" -C "$FETCH_DIR" --strip-components=1
	rm -f "$TMP_TAR"
	echo "$VERSION" >"$FETCH_DIR/.radin-version"

	RADIN_ROOT="$FETCH_DIR"
fi
ok "Using radin source at ${BOLD}$RADIN_ROOT${RESET}"

MANIFEST_VERSION="dev"
[ -f "$RADIN_ROOT/.radin-version" ] && MANIFEST_VERSION="$(cat "$RADIN_ROOT/.radin-version")"

step "Installing agents and skills into ~/.claude"
mkdir -p "$HOME/.claude/agents" "$HOME/.claude/skills" "$HOME/.claude/.radin/lib"
cp "$RADIN_ROOT"/lib/radin-namespace.sh "$HOME/.claude/.radin/lib/"
cp "$RADIN_ROOT"/lib/radin-backlog.sh "$HOME/.claude/.radin/lib/"
cp "$RADIN_ROOT"/lib/radin-prioritization.md "$HOME/.claude/.radin/lib/"
cp "$RADIN_ROOT"/lib/radin-doctor.sh "$HOME/.claude/.radin/lib/"
cp "$RADIN_ROOT"/lib/radin-uninstall.sh "$HOME/.claude/.radin/lib/"
cp "$RADIN_ROOT"/agents/*.md "$HOME/.claude/agents/"
cp -r "$RADIN_ROOT"/skills/radin-review "$HOME/.claude/skills/"
cp -r "$RADIN_ROOT"/skills/radin-record "$HOME/.claude/skills/"
cp -r "$RADIN_ROOT"/skills/radin-show "$HOME/.claude/skills/"
cp -r "$RADIN_ROOT"/skills/radin-plan "$HOME/.claude/skills/"
# thermo-nuclear is vendored via the vercel-labs/skills CLI (agentskills.io
# spec), not a Claude Code plugin -- cursor/plugins isn't a plugin marketplace
# repo, just a SKILL.md at this subpath. Falls back to a raw curl of the file
# if npx isn't available.
if command -v npx >/dev/null 2>&1; then
	NPX_LOG="$(mktemp)"
	if ! npx -y skills add "https://github.com/cursor/plugins/tree/main/cursor-team-kit/skills/thermo-nuclear-code-quality-review" -g -a claude-code -y >"$NPX_LOG" 2>&1; then
		cat "$NPX_LOG" >&2
		rm -f "$NPX_LOG"
		exit 1
	fi
	rm -f "$NPX_LOG"
	# Renamed back to "thermo-nuclear" -- every radin agent/skill invokes it
	# under that name, and skills CLI installs use the source folder's name.
	rm -rf "$HOME/.claude/skills/thermo-nuclear"
	mv "$HOME/.claude/skills/thermo-nuclear-code-quality-review" "$HOME/.claude/skills/thermo-nuclear"
else
	warn "npx not found -- falling back to a direct SKILL.md download for thermo-nuclear."
	mkdir -p "$HOME/.claude/skills/thermo-nuclear"
	curl -fsSL "https://raw.githubusercontent.com/cursor/plugins/refs/heads/main/cursor-team-kit/skills/thermo-nuclear-code-quality-review/SKILL.md" \
		-o "$HOME/.claude/skills/thermo-nuclear/SKILL.md"
fi
# Strip disable-model-invocation so radin-review can invoke thermo-nuclear as
# a sub-skill; upstream sets it to block direct end-user invocation, which
# also blocks our own agent-to-skill call. sed -i differs BSD/GNU -- write to
# temp then mv, portable across both.
THERMO_SKILL="$HOME/.claude/skills/thermo-nuclear/SKILL.md"
if [ -f "$THERMO_SKILL" ]; then
	THERMO_TMP="$(mktemp)"
	grep -v '^disable-model-invocation:' "$THERMO_SKILL" >"$THERMO_TMP"
	mv "$THERMO_TMP" "$THERMO_SKILL"
fi
cp -r "$RADIN_ROOT"/skills/radin-setup-hooks "$HOME/.claude/skills/"
cp -r "$RADIN_ROOT"/skills/radin-stats "$HOME/.claude/skills/"
cp -r "$RADIN_ROOT"/skills/radin-doctor "$HOME/.claude/skills/"
cp -r "$RADIN_ROOT"/skills/radin-uninstall "$HOME/.claude/skills/"
ok "agents/ and skills/ installed"

prompt_yn() {
	# Run from a real file ($0), fd0 is free -- read the answer from stdin
	# (works for an interactive terminal and for piped/redirected answers
	# alike). Piped via curl | bash, fd0 is the script itself, so fall back
	# to /dev/tty. No tty at all (CI, non-interactive) means we can't ask,
	# so default to no.
	local msg="$1" ans=""
	if [ -z "$YES" ]; then
		if [ -f "$0" ]; then
			read -r -p "$(printf "%b" "${YELLOW}${RAT} $msg [y/N]${RESET} ")" ans || true
		elif [ -r /dev/tty ]; then
			read -r -p "$(printf "%b" "${YELLOW}${RAT} $msg [y/N]${RESET} ")" ans </dev/tty || true
		fi
	fi
	[ "$ans" = "y" ] || [ "$ans" = "Y" ]
}

install_if_confirmed() {
	local name="$1" check_cmd="$2" install_cmd="$3" extra_confirm="${4:-}"
	if [ -z "$FORCE" ] && command -v "$check_cmd" >/dev/null 2>&1; then
		ok "$name already installed, skipping."
		return
	fi
	prompt_yn "Install $name?" || return 0
	if [ -n "$extra_confirm" ]; then
		info "$extra_confirm"
		prompt_yn "Confirm: install $name's Python/pip stack?" || return 0
	fi
	eval "$install_cmd"
}

install_plugin_if_confirmed() {
	local name="$1" plugin_id="$2" marketplace_source="$3"
	if [ -z "$FORCE" ] && command -v claude >/dev/null 2>&1 && claude plugin list 2>/dev/null | grep -q "$plugin_id"; then
		ok "$name already installed, skipping."
		return
	fi
	prompt_yn "Install $name?" || return 0
	claude plugin marketplace add "$marketplace_source"
	claude plugin install "$plugin_id"
}

prompt_val() {
	# Same stdin/tty rationale as prompt_yn -- works under curl | bash too.
	local msg="$1" default="$2" ans=""
	if [ -z "$YES" ]; then
		if [ -f "$0" ]; then
			read -r -p "$(printf "%b" "${YELLOW}${RAT} $msg [$default]${RESET} ")" ans || true
		elif [ -r /dev/tty ]; then
			read -r -p "$(printf "%b" "${YELLOW}${RAT} $msg [$default]${RESET} ")" ans </dev/tty || true
		fi
	fi
	printf '%s' "${ans:-$default}"
}

set_agent_model() {
	# No `sed -i`: BSD sed (macOS) and GNU sed (Linux) take incompatible forms
	# of it. Temp-file-plus-mv avoids the divergence entirely.
	local file="$1" pattern="$2" replacement="$3" tmp
	tmp="$(mktemp)"
	sed "s/${pattern}/${replacement}/" "$file" >"$tmp" && mv "$tmp" "$file"
}

step "Agent models (optional)"
if prompt_yn "Choose models for radin-execute? (defaults: sonnet top-level, sonnet sub-agents)"; then
	ORCH_MODEL="$(prompt_val "radin-execute top-level model" "sonnet")"
	ORCH_SUB_MODEL="$(prompt_val "radin-execute sub-agent model (execution + review)" "sonnet")"

	set_agent_model "$HOME/.claude/agents/radin-execute.md" "^model: sonnet$" "model: ${ORCH_MODEL}"
	set_agent_model "$HOME/.claude/agents/radin-execute.md" 'model: "sonnet"' "model: \"${ORCH_SUB_MODEL}\""
	ok "agent model configured"
else
	ok "keeping default models (sonnet top-level, sonnet sub-agents)"
fi

step "Companion tools (all optional)"
# Prefer brew when present (macOS, Linuxbrew). Otherwise delegate to rtk's own
# installer -- it handles Linux OS/arch detection and checksum verification
# itself, so radin doesn't reimplement that here.
if [ -n "$BREW" ]; then
	RTK_INSTALL_CMD="$BREW install rtk"
else
	RTK_INSTALL_CMD="curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh | sh"
fi
install_if_confirmed "rtk" "rtk" "$RTK_INSTALL_CMD"

# code-review-graph ships on PyPI, not npm -- pipx keeps it in its own venv.
install_if_confirmed "code-review-graph" "code-review-graph" \
	"command -v pipx >/dev/null 2>&1 && pipx install code-review-graph || pip3 install --user code-review-graph"

# headroom is a heavier Python/pip stack than rtk's static binary or
# code-review-graph -- gets a second confirmation (install_if_confirmed's
# 4th arg) on top of the normal y/N gate. It complements rtk (whole-session
# wrap vs per-command output compression), not a replacement -- never
# phrase this as preferred over rtk.
install_if_confirmed "headroom" "headroom" \
	"command -v pipx >/dev/null 2>&1 && pipx install headroom-ai || pip3 install --user headroom-ai" \
	"headroom pulls in a Python/pip stack (proxy, MCP, ML, memory -- heavier than rtk's static binary)."

# caveman ships as a Claude Code plugin (not an npm package) -- installs via
# the plugin marketplace flow, same as the interactive `/plugin` command.
install_plugin_if_confirmed "caveman" "caveman@caveman" "JuliusBrussee/caveman"

# i-have-adhd ships as a Claude Code plugin too -- same marketplace flow.
install_plugin_if_confirmed "i-have-adhd" "i-have-adhd@i-have-adhd" "ayghri/i-have-adhd"

# ponytail ships as a Claude Code plugin too -- same marketplace flow.
install_plugin_if_confirmed "ponytail" "ponytail@ponytail" "DietrichGebert/ponytail"

if command -v code-review-graph >/dev/null 2>&1; then
	info "code-review-graph binary installed. To wire its MCP server and hooks"
	info "into a specific project, run the radin-setup-hooks skill from inside"
	info "that project (it edits that repo's .mcp.json / CLAUDE.md, not this one)."
fi

step "Writing install manifest"
# ponytail: three independent copies of this file list already exist
# (install.sh's own cp lines above, radin-doctor.sh, radin-uninstall.sh) --
# a fourth here for the manifest. Dedup if that drift ever bites; out of
# scope for generating the manifest itself.
json_bool_cmd() {
	if command -v "$1" >/dev/null 2>&1; then
		printf 'true'
	else
		printf 'false'
	fi
}
json_bool_plugin() {
	if command -v claude >/dev/null 2>&1 && claude plugin list 2>/dev/null | grep -q "$1"; then
		printf 'true'
	else
		printf 'false'
	fi
}

mkdir -p "$HOME/.claude/.radin"
MANIFEST_FILE="$HOME/.claude/.radin/manifest.json"
INSTALLED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat >"$MANIFEST_FILE" <<EOF
{
  "version": "$MANIFEST_VERSION",
  "installed_at": "$INSTALLED_AT",
  "agents": [
    "radin-execute.md"
  ],
  "skills": [
    "radin-plan",
    "radin-record",
    "radin-review",
    "radin-setup-hooks",
    "radin-show",
    "radin-stats",
    "radin-doctor",
    "radin-uninstall",
    "thermo-nuclear"
  ],
  "lib": [
    "radin-namespace.sh",
    "radin-backlog.sh",
    "radin-prioritization.md",
    "radin-doctor.sh",
    "radin-uninstall.sh"
  ],
  "companion_tools": {
    "rtk": $(json_bool_cmd rtk),
    "code-review-graph": $(json_bool_cmd code-review-graph),
    "headroom": $(json_bool_cmd headroom),
    "caveman": $(json_bool_plugin "caveman@caveman"),
    "i-have-adhd": $(json_bool_plugin "i-have-adhd@i-have-adhd"),
    "ponytail": $(json_bool_plugin "ponytail@ponytail")
  }
}
EOF
ok "manifest written to ${BOLD}$MANIFEST_FILE${RESET}"

step "Done"
ok "radin installed. ${DIM}Go be stingy with those tokens.${RESET}"
