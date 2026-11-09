#!/usr/bin/env bash
# Read-only post-install health check for radin. Confirms the files
# install.sh should have copied are present, and reports which advisory
# companion tools (rtk, codebase-memory-mcp, caveman, ponytail,
# mattpocock-skills, and the unslop and technical-writing skills) are reachable. Never mutates anything -- mirrors install.sh's own
# "advisory only" stance on companion tools.
# Installed to ~/.radin/lib/radin-doctor.sh by install.sh.
#
# Usage: radin-doctor.sh
# Checks every host that ~/.radin/manifest.json lists (none listed means claude).
# The manifest supplies the host list, agents_clis, opencode_allow and the
# files digests. Presence of a shipped file is judged from the filesystem.
# Exit: 0 if every expected agent/skill/lib file is present with its recorded
# digest, no render holds a forbidden string or unresolved token, every lib
# shell script has valid syntax, every settings.json hook command resolves and
# every opencode agent file parses, 1 otherwise. Companion-tool, CLI and Codex
# hook reachability is informational only and never affects the exit code.
# Must stay bash-3.2-compatible (macOS /bin/bash).
set -euo pipefail

CLAUDE_DIR="$HOME/.claude"
RADIN_HOME="$HOME/.radin"
MISSING=0
# BEGIN shipped (generated from SHIPPED by tests/shipped.rs; run make gen, never edit)
SHIPPED_SKILLS="radin-batch radin-do radin-plan radin-record radin-review radin-stats radin-teardown radin-uninstall"
SHIPPED_LIB="radin-host.sh radin-namespace.sh radin-json.sh radin-migrate.sh radin-tui.c forbid-claude.txt forbid-agents.txt radin-update.sh radin-doctor.sh radin-uninstall.sh skill-names-claude.txt skill-names-agents.txt companion-skills.txt"
SHIPPED_HOSTLIB="radin-prompt-planning.md radin-prompt-execution.md radin-prompt-debug.md radin-prompt-factfind.md radin-prompt-gate.md radin-prompt-merge.md radin-leaf-contract.md radin-comment-rule.md radin-explore-rule.md radin-open-decisions.md radin-ask-rule.md radin-complexity-rule.md radin-planning-rule.md radin-prioritization.md radin-batch-recovery.md radin-batch-reporting.md radin-batch-gate.md radin-batch-merge.md radin-batch-clarify.md radin-batch-session.md radin-batch-resume.md radin-run.md radin-review-core.md"
# END shipped

check_file() {
	local label="$1" path="$2"
	if [ -f "$path" ]; then
		printf '  OK       %s\n' "$label"
	else
		printf '  MISSING  %s\n' "$label"
		MISSING=$((MISSING + 1))
	fi
}

check_lib_script() {
	local label="$1" path="$2"
	if [ ! -f "$path" ]; then
		printf '  MISSING  %s\n' "$label"
		MISSING=$((MISSING + 1))
	elif bash -n "$path" 2>/dev/null; then
		printf '  OK       %s\n' "$label"
	else
		printf '  INVALID  %s (syntax error)\n' "$label"
		MISSING=$((MISSING + 1))
	fi
}

check_path_tool() {
	local label="$1" cmd="$2"
	if command -v "$cmd" >/dev/null 2>&1; then
		printf '  %-20s found\n' "$label"
	else
		printf '  %-20s not found\n' "$label"
	fi
}

check_skill() {
	if [ -f "$CLAUDE_DIR/skills/$1/SKILL.md" ]; then
		printf '  %-20s found\n' "$1"
	else
		printf '  %-20s not found\n' "$1"
	fi
}

# Found means enabled at user scope: a disabled or project-only plugin's hooks
# do not run in the user's other repos. ponytail: second copy of install.sh's
# plugin_state.
check_plugin() {
	local label="$1" plugin_id="$2" state=""
	if command -v claude >/dev/null 2>&1; then
		state="$(claude plugin list 2>/dev/null | awk -v id="$plugin_id" '
			/❯ / { cur = ($2 == id); scope = ""; next }
			cur && /Scope:/ { scope = $2 }
			cur && scope == "user" && /Status:/ { state = /disabled/ ? "disabled" : "enabled" }
			END { if (state) print state }
		')"
	fi
	case "$state" in
	enabled) printf '  %-20s found\n' "$label" ;;
	disabled) printf '  %-20s disabled (its hooks do not run: claude plugin enable --scope user %s)\n' "$label" "$plugin_id" ;;
	*) printf '  %-20s not found\n' "$label" ;;
	esac
}

manifest_list() {
	[ -f "$RADIN_HOME/manifest.json" ] || return 0
	sed -n 's/.*"'"$1"'": *\[\([^]]*\)\].*/\1/p' "$RADIN_HOME/manifest.json" | head -1 | tr -d '",'
}
manifest_value() {
	[ -f "$RADIN_HOME/manifest.json" ] || return 0
	sed -n 's/.*"'"$1"'": *"\{0,1\}\([^",]*\)"\{0,1\}.*/\1/p' "$RADIN_HOME/manifest.json" | head -1
}
# `key<TAB>digest` lines of the files map.
manifest_files() {
	[ -f "$RADIN_HOME/manifest.json" ] || return 0
	sed -n '/^  "files": {/,/^  }/p' "$RADIN_HOME/manifest.json" | sed -n 's/^    "\(.*\)": "\(.*\)",\{0,1\}$/\1'"$(printf '\t')"'\2/p'
}
# ponytail: second copy of install.sh's sha256_of
sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | cut -d' ' -f1
	else
		shasum -a 256 "$1" | cut -d' ' -f1
	fi
}

hosts="$(manifest_list hosts)"
agents_clis="$(manifest_list agents_clis)"
host_installed() {
	case " $hosts " in *" $1 "*) return 0 ;; esac
	[ "$1" = claude ] && [ -z "$hosts" ]
}
agents_render=""
if host_installed codex || host_installed opencode; then agents_render=1; fi
codex_dir="${CODEX_HOME:-$HOME/.codex}"
opencode_dir="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"

check_dir() {
	if [ -d "$2" ]; then
		printf '  OK       %s\n' "$1"
	else
		printf '  MISSING  %s\n' "$1"
		MISSING=$((MISSING + 1))
	fi
}

check_guidance() {
	if [ -f "$2" ] && [ "$(grep -c '^<!-- radin:begin -->$' "$2")" -eq 1 ]; then
		printf '  OK       %s\n' "$1"
	else
		printf '  MISSING  %s (re-run install.sh)\n' "$1"
		MISSING=$((MISSING + 1))
	fi
}

check_cli() {
	if command -v "$1" >/dev/null 2>&1; then
		printf '  %-20s found\n' "$1"
	else
		printf '  %-20s not found (companion steps were skipped; install it, then re-run install.sh)\n' "$1"
	fi
}

# True when $1 >= $2, both dotted triples.
version_at_least() {
	awk -v a="$1" -v b="$2" 'BEGIN {
		split(a, x, "."); split(b, y, ".")
		for (i = 1; i <= 3; i++) { if (x[i] + 0 > y[i] + 0) exit 0; if (x[i] + 0 < y[i] + 0) exit 1 }
	}'
}

digest_group() {
	case "$1" in
	.radin/lib/* | .radin/bin/*) echo shared ;;
	.claude/skills/* | .radin/hosts/claude/*) echo claude ;;
	.agents/skills/* | .radin/hosts/agents/*) echo agents ;;
	*/opencode/agents/*) echo opencode ;;
	*) echo other ;;
	esac
}

check_digests() {
	local key want p group n=0 bad=0
	while IFS="$(printf '\t')" read -r key want; do
		group="$(digest_group "$key")"
		case "$group" in
		shared) ;;
		claude | opencode) host_installed "$group" || continue ;;
		agents) [ -n "$agents_render" ] || continue ;;
		*) continue ;;
		esac
		case "$key" in /*) p="$key" ;; *) p="$HOME/$key" ;; esac
		n=$((n + 1))
		if [ ! -f "$p" ]; then
			printf '  MISSING  %s\n' "$p"
			bad=$((bad + 1))
		elif [ "$(sha256_of "$p")" != "$want" ]; then
			printf '  INVALID  %s (changed since install; install.sh --force restores it)\n' "$p"
			bad=$((bad + 1))
		fi
	done < <(manifest_files)
	[ "$n" -eq 0 ] || [ "$bad" -ne 0 ] || printf '  OK       %d file(s) match their recorded digest\n' "$n"
	MISSING=$((MISSING + bad))
}

# Repeats the forbid check install ran on a render: a hand-edited or stale file shows up.
check_forbid() {
	local render="$1" list="$RADIN_HOME/lib/forbid-$1.txt" pats hit dirs="$RADIN_HOME/hosts/$1/lib" name n=0
	pats="$(mktemp)"
	[ ! -f "$list" ] || grep -v '^#\|^$' "$list" >"$pats" || true
	if [ -s "$pats" ]; then
		for name in $SHIPPED_SKILLS; do dirs="$dirs $2/$name"; done
		# shellcheck disable=SC2086  # one path per shipped skill
		hit="$(grep -rFoH --include='*.md' -f "$pats" $dirs 2>/dev/null | awk -F: '!seen[$1]++' || true)"
		while IFS= read -r name; do
			[ -n "$name" ] || continue
			printf '  INVALID  %s (forbidden string "%s" in the %s render)\n' "${name%%:*}" "${name#*:}" "$render"
			n=$((n + 1))
		done <<EOF
$hit
EOF
	fi
	rm -f "$pats"
	[ "$n" -ne 0 ] || printf '  OK       no forbidden string in the %s render\n' "$render"
	MISSING=$((MISSING + n))
}

check_agent_file() {
	local f="$1" fm why=""
	if ! fm="$(awk 'NR == 1 { if ($0 != "---") exit; next } $0 == "---" { closed = 1; exit } { print } END { exit !closed }' "$f")"; then
		why="front matter missing or not closed"
	elif ! printf '%s\n' "$fm" | grep -q '^description:'; then
		why="no description line"
	elif ! printf '%s\n' "$fm" | grep -q '^mode: subagent$'; then
		why="mode is not subagent"
	elif printf '%s\n' "$fm" | grep -q '^tools:'; then
		why="tools line stops opencode from booting"
	fi
	if [ -z "$why" ]; then
		printf '  OK       %s\n' "$f"
	else
		printf '  INVALID  %s (%s)\n' "$f" "$why"
		MISSING=$((MISSING + 1))
	fi
}

check_codex() {
	local out=""
	printf '\nCodex:\n'
	check_cli codex
	check_guidance "$codex_dir/AGENTS.md" "$codex_dir/AGENTS.md"
	if ! grep -qs '"command"' "$codex_dir/hooks.json"; then
		printf '  NOTE     no Codex hooks found (companion hooks missing; re-run install.sh)\n'
	elif ! grep -qs 'trusted_hash' "$codex_dir/config.toml"; then
		printf '  NOTE     Codex hooks untrusted: open /hooks in Codex and trust the new hooks once\n'
	else
		printf '  OK       Codex hook trust recorded (hashes not re-verified)\n'
	fi
	command -v codex >/dev/null 2>&1 || return 0
	# macOS ships no timeout; the probe then runs bare.
	if command -v timeout >/dev/null 2>&1; then
		out="$(timeout 20 codex debug prompt-input 2>&1 </dev/null)" || out=""
	else
		out="$(codex debug prompt-input 2>&1 </dev/null)" || out=""
	fi
	case "$out" in
	*radin-batch*) printf '  OK       Codex lists radin skills\n' ;;
	*) printf '  NOTE     Codex skills listing did not answer (informational)\n' ;;
	esac
}

check_opencode() {
	local v cfg f
	printf '\nopencode:\n'
	check_cli opencode
	check_guidance "$opencode_dir/AGENTS.md" "$opencode_dir/AGENTS.md"
	check_dir "$opencode_dir/agents" "$opencode_dir/agents"
	if command -v opencode >/dev/null 2>&1; then
		v="$(opencode --version 2>/dev/null | grep -o '[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*' | head -1 || true)"
		if [ -z "$v" ]; then
			printf '  NOTE     opencode version not readable\n'
		elif version_at_least "$v" 1.18.29; then
			printf '  OK       opencode %s\n' "$v"
		else
			printf '  INVALID  opencode %s is below 1.18.29\n' "$v"
			MISSING=$((MISSING + 1))
		fi
	fi
	for f in "$opencode_dir"/agents/radin-*.md; do
		[ ! -f "$f" ] || check_agent_file "$f"
	done
	cfg="$(manifest_value opencode_allow)"
	[ -n "$cfg" ] || for f in "$opencode_dir/opencode.json" "$opencode_dir/opencode.jsonc"; do
		[ -f "$f" ] && {
			cfg="$f"
			break
		}
	done
	if [ -n "$cfg" ] && grep -qsF external_directory "$cfg" && grep -qsF "$RADIN_HOME/**" "$cfg"; then
		printf '  OK       external_directory rule for ~/.radin/**\n'
	else
		printf '  MISSING  opencode external_directory rule for ~/.radin/** (re-run install.sh)\n'
		MISSING=$((MISSING + 1))
	fi
}

printf 'radin doctor\n============\n'

if host_installed claude; then
	printf '\nSkills (%s/skills):\n' "$CLAUDE_DIR"
	for name in $SHIPPED_SKILLS thermo-nuclear; do
		check_file "$name" "$CLAUDE_DIR/skills/$name/SKILL.md"
	done
fi

printf '\nLib (%s/lib):\n' "$RADIN_HOME"
printf '\nCLI (%s/bin):\n' "$RADIN_HOME"
check_lib_script "radin (dispatcher)" "$RADIN_HOME/bin/radin"
if [ "$(readlink "$HOME/.local/bin/radin" 2>/dev/null)" = "$RADIN_HOME/bin/radin" ]; then
	printf '  %-20s symlinked into ~/.local/bin\n' "radin (PATH)"
else
	printf '  %-20s not on PATH (optional; skills fall back to the full path)\n' "radin (PATH)"
fi

for name in $SHIPPED_LIB; do
	case "$name" in
	*.sh) check_lib_script "$name" "$RADIN_HOME/lib/$name" ;;
	*) check_file "$name" "$RADIN_HOME/lib/$name" ;;
	esac
done

if host_installed claude; then
	printf '\nLib (%s/hosts/claude/lib):\n' "$RADIN_HOME"
	for name in $SHIPPED_HOSTLIB; do
		check_file "$name" "$RADIN_HOME/hosts/claude/lib/$name"
	done
fi
if [ -n "$agents_render" ]; then
	printf '\nLib (%s/hosts/agents/lib):\n' "$RADIN_HOME"
	for name in $SHIPPED_HOSTLIB; do
		check_file "$name" "$RADIN_HOME/hosts/agents/lib/$name"
	done
fi

# install.sh swaps every RADIN_* token for the recorded answer, and render-host.sh
# every @@skill:NAME@@. One that survived means the run died mid-install, and the
# skill then ships a literal token where a model name or a command belongs. This
# script carries the token names as its own search pattern and ships into the
# scanned lib directory, so exclude it or it always matches itself.
printf '\nInstall-time substitutions:\n'
token_dirs="$RADIN_HOME/lib"
if host_installed claude; then
	for name in $SHIPPED_SKILLS; do token_dirs="$token_dirs $CLAUDE_DIR/skills/$name"; done
	token_dirs="$token_dirs $RADIN_HOME/hosts/claude/lib"
fi
if [ -n "$agents_render" ]; then
	for name in $SHIPPED_SKILLS; do token_dirs="$token_dirs $HOME/.agents/skills/$name"; done
	token_dirs="$token_dirs $RADIN_HOME/hosts/agents/lib"
fi
# shellcheck disable=SC2086  # one path per shipped skill
if grep -rq --exclude=radin-doctor.sh 'RADIN_MODEL_\|RADIN_EFFORT_\|RADIN_CLI \|@@skill:' $token_dirs 2>/dev/null; then
	printf '  INVALID  unsubstituted RADIN_ token -- re-run install.sh\n'
	MISSING=$((MISSING + 1))
else
	printf '  OK       no unsubstituted token left\n'
fi

if host_installed claude; then
	printf '\nHook commands (%s/settings.json):\n' "$CLAUDE_DIR"
	json_helper="$RADIN_HOME/bin/radin-cbm-json"
	if [ ! -x "$json_helper" ]; then
		printf '  SKIPPED  hook commands (radin-cbm-json not built)\n'
	elif [ ! -f "$CLAUDE_DIR/settings.json" ]; then
		printf '  OK       no settings.json, no hooks to check\n'
	elif dead="$("$json_helper" dead-hooks "$CLAUDE_DIR/settings.json")"; then
		printf '  OK       every hook command resolves\n'
	else
		printf '%s\n' "$dead" | sed 's/^DEAD     /  INVALID  hook /'
		MISSING=$((MISSING + $(printf '%s\n' "$dead" | grep -c .)))
	fi
fi

if [ -n "$(manifest_files)" ]; then
	printf '\nDigests (%s/manifest.json):\n' "$RADIN_HOME"
	check_digests
fi

if [ -n "$agents_render" ]; then
	printf '\nAgents render (codex, opencode):\n'
	check_dir "$HOME/.agents/skills" "$HOME/.agents/skills"
	check_dir "$RADIN_HOME/hosts/agents/lib" "$RADIN_HOME/hosts/agents/lib"
	check_forbid agents "$HOME/.agents/skills"
	case " $agents_clis " in
	*" codex "*"opencode "* | *" opencode "*" codex "*)
		printf '  NOTE     codex and opencode share ~/.agents/skills: one render serves both\n'
		;;
	esac
fi
if host_installed claude; then check_forbid claude "$CLAUDE_DIR/skills"; fi
if host_installed codex; then check_codex; fi
if host_installed opencode; then check_opencode; fi

printf '\nCompanion tools (optional, advisory-only):\n'
check_path_tool "rtk" "rtk"
check_path_tool "codebase-memory-mcp" "codebase-memory-mcp"
if host_installed claude; then
	check_plugin "caveman" "caveman@caveman"
	check_plugin "ponytail" "ponytail@ponytail"
	check_plugin "mattpocock-skills" "mattpocock-skills@claude-plugins-official"
	check_skill "unslop"
	check_skill "technical-writing"
fi

if [ -n "$agents_clis" ]; then
	printf '\nAgents companion skills (~/.agents/skills):\n'
	while read -r name; do
		found=""
		[ ! -f "$HOME/.agents/skills/$name/SKILL.md" ] || found=1
		# Codex reads only ~/.agents/skills, so a copy in the opencode dir breaks Codex runs.
		case " $agents_clis " in
		*" codex "*) ;;
		*" opencode "*) [ ! -f "$opencode_dir/skills/$name/SKILL.md" ] || found=1 ;;
		esac
		if awk -v k="$name" '$1 == k { f = 1 } END { exit !f }' "$RADIN_HOME/lib/skill-names-agents.txt"; then
			# An invoked name that does not resolve breaks runs.
			if [ -n "$found" ]; then printf '  OK       %s\n' "$name"; else
				printf '  MISSING  %s\n' "$name"
				MISSING=$((MISSING + 1))
			fi
		elif [ -n "$found" ]; then
			printf '  %-20s found\n' "$name"
		else
			printf '  %-20s not found\n' "$name"
		fi
	done < <(awk '!/^#/ && NF { print $1 }' "$RADIN_HOME/lib/companion-skills.txt")
fi

# Informational, like every companion check: the graph binary can be installed
# and still answer nothing if its Claude Code wiring never landed.
if host_installed claude && { command -v codebase-memory-mcp >/dev/null 2>&1 || [ -x "$HOME/.local/bin/codebase-memory-mcp" ]; }; then
	printf '\ncodebase-memory-mcp wiring (informational):\n'
	# Match the hook command path, which is the tool's own name: it ships no
	# "cbm" string of its own, so that shorthand matched nothing.
	if [ -f "$CLAUDE_DIR/settings.json" ] && grep -q 'codebase-memory-mcp' "$CLAUDE_DIR/settings.json"; then
		printf '  OK       hooks in %s/settings.json\n' "$CLAUDE_DIR"
	else
		printf '  MISSING  hooks in %s/settings.json (re-run install.sh, or radin hooks all)\n' "$CLAUDE_DIR"
	fi
	if { [ -f "$HOME/.claude.json" ] && grep -q 'codebase-memory-mcp' "$HOME/.claude.json"; } ||
		{ [ -f "$PWD/.mcp.json" ] && grep -q 'codebase-memory-mcp' "$PWD/.mcp.json"; }; then
		printf '  OK       MCP server entry (user scope or this repo)\n'
	else
		printf '  MISSING  MCP server entry -- re-run install.sh, or radin hooks mcp here\n'
	fi
	if [ -d "$RADIN_HOME/backups" ]; then
		printf '  OK       config snapshots in %s/backups\n' "$RADIN_HOME"
	fi
fi

printf '\n'
if [ "$MISSING" -eq 0 ]; then
	printf 'All expected files present.\n'
	exit 0
else
	printf '%d check(s) failed (missing file, invalid file or unresolved hook).\n' "$MISSING"
	exit 1
fi
