#!/usr/bin/env bash
set -euo pipefail

BREW="$(command -v brew || true)"
if [ -z "$BREW" ]; then
  echo "Homebrew not found. Install from https://brew.sh, then re-run." >&2
  exit 1
fi
eval "$("$BREW" shellenv)"

REPO_URL="https://github.com/shortcuts/radin.git"
DEFAULT_CLONE_DIR="$HOME/.claude/radin"

# Resolve RADIN_ROOT from the running script's own location -- works when
# executed from a real git clone (./install.sh). Piped via curl | bash,
# BASH_SOURCE[0] has no usable sibling agents/skills dirs, so this returns
# empty and the block below self-clones instead.
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

RADIN_ROOT="$(resolve_radin_root)"
if [ -z "$RADIN_ROOT" ]; then
  command -v git >/dev/null 2>&1 || { echo "git not found. Install git, then re-run." >&2; exit 1; }
  TARGET="${RADIN_ROOT_OVERRIDE:-$DEFAULT_CLONE_DIR}"
  if [ -d "$TARGET" ]; then
    if [ -d "$TARGET/.git" ]; then
      echo "Updating existing radin clone at $TARGET..."
      git -C "$TARGET" pull
    else
      echo "$TARGET exists and isn't a git repo -- remove it or set RADIN_ROOT_OVERRIDE to a different path, then re-run." >&2
      exit 1
    fi
  else
    echo "Cloning radin to $TARGET..."
    git clone "$REPO_URL" "$TARGET"
  fi
  RADIN_ROOT="$TARGET"
fi

mkdir -p "$HOME/.claude/agents" "$HOME/.claude/skills"
cp "$RADIN_ROOT"/agents/*.md "$HOME/.claude/agents/"
cp -r "$RADIN_ROOT"/skills/radin-review "$HOME/.claude/skills/"
mkdir -p "$HOME/.claude/skills/thermo-nuclear"
curl -fsSL "https://raw.githubusercontent.com/cursor/plugins/refs/heads/main/cursor-team-kit/skills/thermo-nuclear-code-quality-review/SKILL.md" \
  -o "$HOME/.claude/skills/thermo-nuclear/SKILL.md"
cp -r "$RADIN_ROOT"/skills/radin-setup-hooks "$HOME/.claude/skills/"
cp -r "$RADIN_ROOT"/skills/radin-update "$HOME/.claude/skills/"

mkdir -p "$HOME/.claude/.radin/projects"
[ -f "$HOME/.claude/.radin/registry.json" ] || echo '{}' > "$HOME/.claude/.radin/registry.json"
echo "$RADIN_ROOT" > "$HOME/.claude/.radin/install_root"

install_if_confirmed() {
  local name="$1" check_cmd="$2" install_cmd="$3"
  if command -v "$check_cmd" >/dev/null 2>&1; then
    echo "$name already installed, skipping."
    return
  fi
  read -r -p "Install $name? [y/N] " ans
  [ "$ans" = "y" ] || [ "$ans" = "Y" ] || return
  eval "$install_cmd"
}

install_plugin_if_confirmed() {
  local name="$1" plugin_id="$2" marketplace_source="$3"
  if command -v claude >/dev/null 2>&1 && claude plugin list 2>/dev/null | grep -q "$plugin_id"; then
    echo "$name already installed, skipping."
    return
  fi
  read -r -p "Install $name? [y/N] " ans
  [ "$ans" = "y" ] || [ "$ans" = "Y" ] || return
  claude plugin marketplace add "$marketplace_source"
  claude plugin install "$plugin_id"
}

install_if_confirmed "rtk" "rtk" "$BREW install rtk"

# code-review-graph ships on PyPI, not npm -- pipx keeps it in its own venv.
install_if_confirmed "code-review-graph" "code-review-graph" \
  "command -v pipx >/dev/null 2>&1 && pipx install code-review-graph || pip3 install --user code-review-graph"

# caveman ships as a Claude Code plugin (not an npm package) -- installs via
# the plugin marketplace flow, same as the interactive `/plugin` command.
install_plugin_if_confirmed "caveman" "caveman@caveman" "JuliusBrussee/caveman"

if command -v code-review-graph >/dev/null 2>&1; then
  echo "code-review-graph binary installed. To wire its MCP server and hooks"
  echo "into a specific project, run the radin-setup-hooks skill from inside"
  echo "that project (it edits that repo's .mcp.json / CLAUDE.md, not this one)."
fi
