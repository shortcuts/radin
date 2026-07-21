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
for arg in "$@"; do
	[ "$arg" = "--force" ] && FORCE="1"
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
if [ -z "$BREW" ]; then
	printf "%b\n" "${RED}${RAT} Homebrew not found.${RESET} Install from https://brew.sh, then re-run." >&2
	exit 1
fi
eval "$("$BREW" shellenv)"

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

	VERSION="$(curl -fsSL "$API_LATEST_RELEASE" 2>/dev/null | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')"
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
	rm -rf "$FETCH_DIR"
	mkdir -p "$FETCH_DIR"
	tar -xzf "$TMP_TAR" -C "$FETCH_DIR" --strip-components=1
	rm -f "$TMP_TAR"
	echo "$VERSION" >"$FETCH_DIR/.radin-version"

	RADIN_ROOT="$FETCH_DIR"
fi
ok "Using radin source at ${BOLD}$RADIN_ROOT${RESET}"

step "Installing agents and skills into ~/.claude"
mkdir -p "$HOME/.claude/agents" "$HOME/.claude/skills" "$HOME/.claude/radin-lib"
cp "$RADIN_ROOT"/lib/radin-namespace.sh "$HOME/.claude/radin-lib/"
cp "$RADIN_ROOT"/agents/*.md "$HOME/.claude/agents/"
cp -r "$RADIN_ROOT"/skills/radin-review "$HOME/.claude/skills/"
cp -r "$RADIN_ROOT"/skills/radin-record "$HOME/.claude/skills/"
mkdir -p "$HOME/.claude/skills/thermo-nuclear"
curl -fsSL "https://raw.githubusercontent.com/cursor/plugins/refs/heads/main/cursor-team-kit/skills/thermo-nuclear-code-quality-review/SKILL.md" \
	-o "$HOME/.claude/skills/thermo-nuclear/SKILL.md"
cp -r "$RADIN_ROOT"/skills/radin-setup-hooks "$HOME/.claude/skills/"
cp -r "$RADIN_ROOT"/skills/radin-update "$HOME/.claude/skills/"
ok "agents/ and skills/ installed"

mkdir -p "$HOME/.claude/.radin/projects"
[ -f "$HOME/.claude/.radin/registry.json" ] || echo '{}' >"$HOME/.claude/.radin/registry.json"
echo "$RADIN_ROOT" >"$HOME/.claude/.radin/install_root"

install_if_confirmed() {
	local name="$1" check_cmd="$2" install_cmd="$3"
	if [ -z "$FORCE" ] && command -v "$check_cmd" >/dev/null 2>&1; then
		ok "$name already installed, skipping."
		return
	fi
	read -r -p "$(printf "%b" "${YELLOW}${RAT} Install $name? [y/N]${RESET} ")" ans
	[ "$ans" = "y" ] || [ "$ans" = "Y" ] || return 0
	eval "$install_cmd"
}

install_plugin_if_confirmed() {
	local name="$1" plugin_id="$2" marketplace_source="$3"
	if [ -z "$FORCE" ] && command -v claude >/dev/null 2>&1 && claude plugin list 2>/dev/null | grep -q "$plugin_id"; then
		ok "$name already installed, skipping."
		return
	fi
	read -r -p "$(printf "%b" "${YELLOW}${RAT} Install $name? [y/N]${RESET} ")" ans
	[ "$ans" = "y" ] || [ "$ans" = "Y" ] || return 0
	claude plugin marketplace add "$marketplace_source"
	claude plugin install "$plugin_id"
}

step "Companion tools (all optional)"
install_if_confirmed "rtk" "rtk" "$BREW install rtk"

# code-review-graph ships on PyPI, not npm -- pipx keeps it in its own venv.
install_if_confirmed "code-review-graph" "code-review-graph" \
	"command -v pipx >/dev/null 2>&1 && pipx install code-review-graph || pip3 install --user code-review-graph"

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

step "Done"
ok "radin installed. ${DIM}Go be stingy with those tokens.${RESET}"
