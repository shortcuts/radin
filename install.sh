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

YES=""
UPDATE=""
VERBOSE=""
LIST=""
DRY=""
FORCE=""
ONLY=""
ONLY_SET=""

# id|label|mechanism|cli. A string table: bash 3.2 has no associative arrays.
# The mechanism names the render a host reads: claude, or agents (Codex and opencode).
HOSTS="claude|Claude Code|claude|claude
codex|Codex CLI|agents|codex
opencode|opencode|agents|opencode"
host_ids() { printf '%s\n' "$HOSTS" | cut -d'|' -f1; }
host_field() { printf '%s\n' "$HOSTS" | awk -F'|' -v id="$1" -v n="$2" '$1 == id { print $n }'; }
# `~/.claude` alone counts for claude: the install works without the CLI.
host_detected() {
	if [ "$1" = claude ] && [ -d "$HOME/.claude" ]; then return 0; fi
	command -v "$(host_field "$1" 4)" >/dev/null 2>&1
}

usage_exit() {
	printf 'usage: install.sh [--yes] [--verbose] [--update] [--list] [--dry-run] [--force] [--only ID[,ID...]]\n' >&2
	printf 'hosts: %s\n' "$(host_ids | tr '\n' ' ')" >&2
	exit 2
}

SELECTED=""
host_selected() {
	case " $SELECTED " in *" $1 "*) return 0 ;; esac
	return 1
}
# Keeps table order and drops duplicates; an id outside the table is a usage error.
select_ids() {
	local want="$1" id
	for id in $(printf '%s' "$want" | tr ',' ' '); do
		[ -n "$(host_field "$id" 1)" ] || usage_exit
	done
	SELECTED=""
	for id in $(host_ids); do
		case ",$want," in *",$id,"*) SELECTED="$SELECTED $id" ;; esac
	done
	SELECTED="${SELECTED# }"
	[ -n "$SELECTED" ] || usage_exit
}

while [ $# -gt 0 ]; do
	case "$1" in
	--yes) YES="1" ;;
	--verbose) VERBOSE="1" ;;
	# --update is what `radin update` runs: every step, but a companion already
	# installed is not reinstalled. Companion tools have their own update
	# paths; a plain install re-runs every one of them.
	--update) UPDATE="1" ;;
	--list) LIST="1" ;;
	--dry-run) DRY="1" ;;
	--force) FORCE="1" ;;
	--only)
		[ $# -ge 2 ] || usage_exit
		ONLY="$2"
		ONLY_SET="1"
		shift
		;;
	--only=*)
		ONLY="${1#--only=}"
		ONLY_SET="1"
		;;
	*) usage_exit ;;
	esac
	shift
done
[ -z "$ONLY_SET" ] || select_ids "$ONLY"

if [ -n "$LIST" ]; then
	for id in $(host_ids); do
		if host_detected "$id"; then detected=yes; else detected=no; fi
		printf '%s\t%s\t%s\n' "$id" "$(host_field "$id" 2)" "$detected"
	done
	exit 0
fi

RADIN_HOME="$HOME/.radin"
MANIFEST_FILE="$RADIN_HOME/manifest.json"
# Flat `"key": value` lookup in the previous manifest. Prints nothing for a
# missing key, so every caller keeps its own default.
manifest_value() {
	[ -f "$MANIFEST_FILE" ] || return 0
	sed -n 's/.*"'"$1"'": *"\{0,1\}\([^",]*\)"\{0,1\}.*/\1/p' "$MANIFEST_FILE" | head -1
}
# Words of a one-line JSON array of plain names. A v1 manifest has no such key.
manifest_list() {
	[ -f "$MANIFEST_FILE" ] || return 0
	sed -n 's/.*"'"$1"'": *\[\([^]]*\)\].*/\1/p' "$MANIFEST_FILE" | head -1 | tr -d '",'
}

# --verbose traces every command and lets companion installs write straight to
# the terminal. A hang shows the command it is stuck in, which a captured log
# cannot: the log is only read after the command returns.
if [ -n "$VERBOSE" ]; then
	PS4='+ install.sh:${LINENO}: '
	set -x
fi

RAT='🐀'
info() { printf "%b\n" "${CYAN}${RAT}${RESET} $*"; }
ok() { printf "%b\n" "${GREEN}${RAT}${RESET} $*"; }
warn() { printf "%b\n" "${YELLOW}${RAT}${RESET} $*"; }
step() { printf "\n%b\n" "${BOLD}${MAGENTA}${RAT} $*${RESET}"; }

# A child that swallowed fd0 used to end the run here with status 0 and a
# half-populated ~/.claude, silently. Say so instead.
INSTALL_DONE=""
# shellcheck disable=SC2154 # st is set by the trap body itself.
trap 'st=$?; [ -n "$INSTALL_DONE" ] || [ "$st" = 130 ] || printf "%b\n" "${RED}${RAT} install stopped early ($st) -- ~/.claude holds a partial install. Re-run it, or check with: radin doctor${RESET}" >&2' EXIT

_pick_nth() {
	local want="$1" i=1 opt
	shift
	for opt in "$@"; do
		if [ "$i" = "$want" ]; then
			printf '%s' "$opt"
			return
		fi
		i=$((i + 1))
	done
}

_pick_tui() {
	# Arrow-key picker on a real terminal. Draws to the tty, never to stdout,
	# so the caller can still capture the chosen option. Returns 1 when the
	# device can't be put in raw mode, and the numbered fallback takes over.
	local dev="$1" msg="$2" sel="$3"
	shift 3
	local count=$# saved key rest i opt
	local esc=$'\033' cr=$'\r' etx=$'\003' eot=$'\004'
	saved="$(stty -g <"$dev" 2>/dev/null)" || return 1
	printf "%b\n" "${YELLOW}${RAT} $msg${RESET} ${DIM}(arrows, enter to confirm)${RESET}" >"$dev"
	stty raw -echo <"$dev" 2>/dev/null || return 1
	printf '\033[?25l' >"$dev"
	while :; do
		i=1
		for opt in "$@"; do
			# Raw mode drops the NL->CRNL translation, hence the explicit \r.
			if [ "$i" = "$sel" ]; then
				printf '\r\033[K %b\r\n' "${CYAN}>${RESET} ${BOLD}$opt${RESET}" >"$dev"
			else
				printf '\r\033[K   %s\r\n' "$opt" >"$dev"
			fi
			i=$((i + 1))
		done
		IFS= read -r -n1 key <"$dev" || break
		case "$key" in
		"$esc")
			# An arrow key arrives as three bytes at once, so no timeout needed.
			IFS= read -r -n2 rest <"$dev" || break
			case "$rest" in
			'[A' | '[D') sel=$((sel > 1 ? sel - 1 : count)) ;;
			'[B' | '[C') sel=$((sel < count ? sel + 1 : 1)) ;;
			esac
			;;
		k) sel=$((sel > 1 ? sel - 1 : count)) ;;
		j) sel=$((sel < count ? sel + 1 : 1)) ;;
		[1-9])
			if [ "$key" -le "$count" ]; then
				sel="$key"
			fi
			;;
		'' | "$cr") break ;;
		# raw mode turns off ISIG, so Ctrl-C and Ctrl-D arrive as bytes -- honour
		# them here or the picker becomes unquittable.
		"$etx" | "$eot")
			printf '\033[?25h' >"$dev"
			stty "$saved" <"$dev"
			printf "\n%b\n" "${RED}${RAT} aborted.${RESET}" >"$dev"
			exit 130
			;;
		esac
		printf '\033[%dA' "$count" >"$dev"
	done
	printf '\033[?25h' >"$dev"
	stty "$saved" <"$dev"
	_pick_nth "$sel" "$@"
}

_pick_numbered() {
	# Fallback for anything that isn't an interactive terminal: piped answers,
	# CI, or a tty that rejects raw mode. Anything unparseable takes the
	# default, so a typo can't be read as a silent "no".
	local dev="$1" msg="$2" default="$3"
	shift 3
	local count=$# ans="" i=1 opt label
	printf "%b\n" "${YELLOW}${RAT} $msg${RESET}" >&2
	for opt in "$@"; do
		if [ "$i" = "$default" ]; then
			printf "  %b\n" "${BOLD}$i${RESET}) $opt ${DIM}(default)${RESET}" >&2
		else
			printf "  %b\n" "${BOLD}$i${RESET}) $opt" >&2
		fi
		i=$((i + 1))
	done
	label="$(printf "%b" "${YELLOW}${RAT} Pick 1-${count} [${default}]${RESET} ")"
	if [ "$dev" = "-" ]; then
		read -r -p "$label" ans || true
	else
		read -r -p "$label" ans <"$dev" || true
	fi
	case "$ans" in
	'' | *[!0-9]*) ans="$default" ;;
	esac
	if [ "$ans" -lt 1 ] || [ "$ans" -gt "$count" ]; then
		ans="$default"
	fi
	_pick_nth "$ans" "$@"
}

prompt_pick() {
	# Interactive stdin (./install.sh from a terminal): arrow-key picker there.
	# Run from a real file with stdin piped, fd0 carries the answers, so read
	# them as numbers. Piped via curl | bash, fd0 is the script itself -- the
	# terminal is only reachable through /dev/tty. Nothing readable at all
	# (CI, --yes) means we can't ask, so take the default.
	local msg="$1" default="$2"
	shift 2
	if [ -z "$YES" ]; then
		if [ -t 0 ]; then
			_pick_tui /dev/tty "$msg" "$default" "$@" && return
			_pick_numbered /dev/tty "$msg" "$default" "$@"
			return
		elif [ -f "$0" ]; then
			_pick_numbered - "$msg" "$default" "$@"
			return
		elif [ -r /dev/tty ]; then
			_pick_tui /dev/tty "$msg" "$default" "$@" && return
			_pick_numbered /dev/tty "$msg" "$default" "$@"
			return
		fi
	fi
	_pick_nth "$default" "$@"
}

prompt_yn() {
	[ "$(prompt_pick "$1" 2 "yes" "no")" = "yes" ]
}

printf "%b\n" "${BOLD}${MAGENTA}"
printf "%s\n" "  🐀 radin — stingy on tokens, generous on backlog throughput"
printf "%b\n" "${RESET}${DIM}  Installs backlog-workflow skills into ~/.claude, plus the whole curated"
printf "%b\n\n" "  token-saving stack. Only execution behaviour and your package manager are asked about.${RESET}"

# A terminal can answer a question: stdin is one, or the script is piped and /dev/tty opens.
have_tty() {
	[ -z "$YES" ] || return 1
	[ -t 0 ] && return 0
	[ ! -f "$0" ] && (: </dev/tty) 2>/dev/null
}

# --only wins; an update reuses the manifest (no manifest hosts key means a v1 install, claude only);
# a terminal gets one question per detected host; anything else installs claude.
select_hosts() {
	local id ids="" want="" default
	[ -z "$ONLY_SET" ] || return 0
	if [ -n "$UPDATE" ]; then
		for id in $(manifest_list hosts); do
			[ -z "$(host_field "$id" 1)" ] || want="$want,$id"
		done
		want="${want#,}"
		select_ids "${want:-claude}"
		return
	fi
	if have_tty; then
		for id in $(host_ids); do
			host_detected "$id" && ids="$ids $id"
		done
		case "$ids" in
		" claude" | "") ;;
		*)
			for id in $ids; do
				default=2
				[ "$id" != claude ] || default=1
				if [ "$(prompt_pick "Install radin for $(host_field "$id" 2)?" "$default" yes no)" = yes ]; then
					want="$want,$id"
				fi
			done
			if [ -z "$want" ]; then
				INSTALL_DONE="1"
				info "nothing selected"
				exit 0
			fi
			select_ids "${want#,}"
			return
			;;
		esac
	fi
	select_ids claude
}
select_hosts
info "hosts: $SELECTED"

# No `brew shellenv` eval: it prepends brew's bin to PATH and would shadow a
# version-manager python3 (mise/pyenv) with brew's -- probing the wrong
# interpreter in the pyexpat preflight below. brew itself is called via $BREW.
BREW="$(command -v brew || true)"
MISE="$(command -v mise || true)"

GITHUB_REPO="shortcuts/radin"
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
		if [ -d "$dir/skills" ] && [ -d "$dir/lib" ]; then
			printf '%s' "$dir"
			return
		fi
	fi
	printf '%s' ""
}

step "Resolving radin source"
RADIN_ROOT="$(resolve_radin_root)"
if [ -z "$RADIN_ROOT" ] && [ -n "$DRY" ]; then
	RADIN_ROOT="${RADIN_ROOT_OVERRIDE:-$DEFAULT_FETCH_DIR}"
	info "would download $TARBALL_BASE/refs/heads/main.tar.gz"
elif [ -z "$RADIN_ROOT" ]; then
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

	# Piped from main, so fetch main: a release tag predates the files main's SHIPPED_LIB names.
	VERSION="main"
	TARBALL_URL="$TARBALL_BASE/refs/heads/main.tar.gz"

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

OLD_HOME="$HOME/.claude/.radin"
MIGRATING="$HOME/.radin.migrating"
MIGRATED=""
LEGACY_LEFT=""

radin_home_at() {
	[ -f "$1/manifest.json" ] && grep -q '"installed_at"' "$1/manifest.json" && grep -q '"companion_tools"' "$1/manifest.json"
}

migrate_abort() {
	INSTALL_DONE="1"
	printf "%b\n" "${RED}${RAT} $*${RESET}" >&2
	exit 1
}

path_taken() { [ -e "$1" ] || [ -L "$1" ]; }

# Two renames, not one: a cross-device `mv` copies, then deletes, and a copy
# that dies halfway must not leave a ~/.radin that passes radin_home_at.
migrate_home() {
	radin_home_at "$OLD_HOME" || return 0
	if [ -n "$DRY" ]; then
		info "would move $OLD_HOME to $RADIN_HOME"
		return 0
	fi
	if path_taken "$RADIN_HOME"; then
		if radin_home_at "$RADIN_HOME"; then
			warn "$OLD_HOME is still there, unused: delete it by hand once you checked it."
			LEGACY_LEFT="1"
			return 0
		fi
		migrate_abort "$RADIN_HOME is not radin's: move it away, then re-run."
	fi
	if path_taken "$MIGRATING"; then
		migrate_abort "$MIGRATING was left by an interrupted move: inspect it, move it away, then re-run."
	fi
	mv "$OLD_HOME" "$MIGRATING" ||
		migrate_abort "mv failed: $OLD_HOME is intact; the partial copy is at $MIGRATING."
	mv "$MIGRATING" "$RADIN_HOME" ||
		migrate_abort "mv failed: the data is at $MIGRATING, $OLD_HOME is gone; move it to $RADIN_HOME by hand."
	MIGRATED="1"
	ok "moved ~/.claude/.radin to ~/.radin"
}
migrate_home

MANIFEST_VERSION="dev"
[ -f "$RADIN_ROOT/.radin-version" ] && MANIFEST_VERSION="$(cat "$RADIN_ROOT/.radin-version")"

step "Installing radin into ~/.radin and skills into ~/.claude"
# Explicit names from SHIPPED, not lib/* or skills/* globs: install.sh may only
# copy files radin itself named (AGENTS.md Constraints), and a stray file in a
# dev clone must not ship.
# BEGIN shipped (generated from SHIPPED by scripts/shipped.sh; run make gen, never edit)
SHIPPED_SKILLS="radin-batch radin-do radin-plan radin-record radin-review radin-stats radin-teardown radin-uninstall"
SHIPPED_LIB="radin-host.sh radin-namespace.sh radin-json.sh radin-backlog.sh radin-tui.c radin-cbm-json.c radin-state.sh radin-scope.sh radin-prompt.sh radin-cbm-hooks.sh radin-cbm-config.sh radin-update.sh radin-stats.sh radin-doctor.sh radin-uninstall.sh skill-names-claude.txt skill-names-agents.txt"
SHIPPED_HOSTLIB="radin-prompt-planning.md radin-prompt-execution.md radin-prompt-debug.md radin-prompt-factfind.md radin-prompt-gate.md radin-prompt-merge.md radin-leaf-contract.md radin-comment-rule.md radin-explore-rule.md radin-open-decisions.md radin-ask-rule.md radin-complexity-rule.md radin-planning-rule.md radin-prioritization.md radin-batch-recovery.md radin-batch-reporting.md radin-batch-gate.md radin-batch-merge.md radin-batch-clarify.md radin-batch-session.md radin-batch-resume.md radin-run.md radin-review-core.md"
RENAMED_SKILLS="radin-execute radin-implement radin-run"
RETIRED_SKILLS="radin-update radin-show radin-doctor radin-setup-hooks"
RETIRED_LIB="radin-tui.sh radin-crg-hooks.sh radin-execute-recovery.md radin-execute-reporting.md radin-execute-gate.md radin-execute-review.md radin-execute-clarify.md radin-execute-session.md radin-execute-resume.md radin-batch-review.md"
# END shipped
PSTACK_RAW="https://raw.githubusercontent.com/cursor/plugins/refs/heads/main/pstack/skills"
CBM_INSTALL_CMD="curl -fsSL https://raw.githubusercontent.com/DeusData/codebase-memory-mcp/main/install.sh | bash -s -- --skip-config"
# `skills@latest`: a bare `skills` reuses whatever CLI version npx cached.
THERMO_INSTALL_CMD='npx -y skills@latest add "https://github.com/cursor/plugins/tree/main/cursor-team-kit/skills/thermo-nuclear-code-quality-review" -g -a claude-code -y'
# brew refreshes its formula index before installing: with that refresh
# off, it installs whatever version the last `brew update` saw.
rtk_cmd() {
	case "$1" in
	brew) printf '%s' "$BREW install rtk || $BREW upgrade rtk" ;;
	mise) printf '%s' "$MISE use -g aqua:rtk-ai/rtk@latest" ;;
	*) printf '%s' "curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh | sh" ;;
	esac
}

host_skills_dir() {
	if [ "$1" = claude ]; then printf '%s' "$HOME/.claude/skills"; else printf '%s' "$HOME/.agents/skills"; fi
}

# The renders the selected hosts read: claude, agents, or both.
RENDERS=""
set_renders() {
	local id m
	RENDERS=""
	for id in $SELECTED; do
		m="$(host_field "$id" 3)"
		case " $RENDERS " in *" $m "*) ;; *) RENDERS="$RENDERS $m" ;; esac
	done
	RENDERS="${RENDERS# }"
}

# One path per line for every file radin writes into a manifest `files` entry.
# Read from the source tree, so a dry run and a real run list the same files.
owned_paths() {
	local r s f
	for f in $SHIPPED_LIB; do printf '%s\n' "$RADIN_HOME/lib/$f"; done
	printf '%s\n' "$RADIN_HOME/bin/radin"
	for r in $RENDERS; do
		for f in $SHIPPED_HOSTLIB; do printf '%s\n' "$RADIN_HOME/hosts/$r/lib/$f"; done
		for s in $SHIPPED_SKILLS; do
			if [ -d "$RADIN_ROOT/skills/$s" ]; then
				(cd "$RADIN_ROOT/skills" && find "$s" -type f | sort) | sed "s|^|$(host_skills_dir "$r")/|"
			else
				printf '%s/%s/\n' "$(host_skills_dir "$r")" "$s"
			fi
		done
	done
}

dry_run_report() {
	local p mgr
	info "dry run: nothing below is written or run"
	info "hosts: $SELECTED${FORCE:+ (--force: backups come with the preflight)}"
	while IFS= read -r p; do printf 'write %s\n' "$p"; done < <(owned_paths)
	printf 'write %s\n' "$RADIN_HOME/install_root" "$MANIFEST_FILE" "$RADIN_HOME/bin/radin-tui" \
		"$RADIN_HOME/bin/radin-cbm-json" "$HOME/.local/bin/radin"
	if host_selected claude; then
		printf 'write %s\n' "$HOME/.claude/CLAUDE.md" "$HOME/.claude/settings.json"
	fi
	mgr="$(manifest_value package_manager)"
	if [ -z "$mgr" ]; then
		if [ -n "$BREW" ]; then mgr=brew; elif [ -n "$MISE" ]; then mgr=mise; else mgr=curl; fi
	fi
	printf 'run %s\n' "$(rtk_cmd "$mgr")" "$CBM_INSTALL_CMD"
	if host_selected claude; then
		printf 'run %s\n' "$THERMO_INSTALL_CMD" \
			"curl -fsSL $PSTACK_RAW/unslop/SKILL.md" "curl -fsSL $PSTACK_RAW/technical-writing/SKILL.md" \
			"claude plugin install caveman@caveman" "claude plugin install ponytail@ponytail" \
			"claude plugin install mattpocock-skills@claude-plugins-official"
	fi
}
[ -z "$DRY" ] || {
	set_renders
	dry_run_report
	INSTALL_DONE="1"
	exit 0
}
set_renders
mkdir -p "$RADIN_HOME/lib"
for f in $SHIPPED_LIB; do
	cp "$RADIN_ROOT/lib/$f" "$RADIN_HOME/lib/"
done
if host_selected claude; then
	mkdir -p "$HOME/.claude/skills" "$RADIN_HOME/hosts/claude/lib"
	for f in $SHIPPED_HOSTLIB; do
		cp "$RADIN_ROOT/lib/$f" "$RADIN_HOME/hosts/claude/lib/"
	done
	for s in $SHIPPED_SKILLS; do
		cp -r "$RADIN_ROOT/skills/$s" "$HOME/.claude/skills/"
	done
fi

# A moved home still holds the pre-split rendered .md files and retired libs.
if [ -n "$MIGRATED" ]; then
	for f in $SHIPPED_HOSTLIB $RETIRED_LIB; do
		rm -f "$RADIN_HOME/lib/$f"
	done
fi

# Only a dir whose SKILL.md still names itself is radin's own to remove.
if host_selected claude; then
	for s in $RENAMED_SKILLS $RETIRED_SKILLS; do
		if grep -qx "name: $s" "$HOME/.claude/skills/$s/SKILL.md" 2>/dev/null; then
			rm -rf "$HOME/.claude/skills/$s"
		fi
	done
fi
mkdir -p "$RADIN_HOME/bin"
cp "$RADIN_ROOT/bin/radin" "$RADIN_HOME/bin/"
chmod +x "$RADIN_HOME/bin/radin"

# The TUI and the cbm-config JSON helper are C, so they are the two files
# built here rather than copied. Advisory like a companion tool: a box with no
# compiler keeps every other subcommand -- `radin backlog show` covers the
# reading the TUI does, and `radin cbm-hooks all` covers the merge-only wiring
# `radin cbm-config` would have done.
TUI_CC="$(command -v cc || command -v gcc || command -v clang || true)"
if [ -n "$TUI_CC" ]; then
	CC_LOG="$(mktemp)"
	if "$TUI_CC" -O2 -o "$RADIN_HOME/bin/radin-tui" \
		"$RADIN_HOME/lib/radin-tui.c" >"$CC_LOG" 2>&1; then
		ok "TUI built."
	else
		tail -n 20 "$CC_LOG" >&2
		warn "the TUI failed to build -- every other subcommand still works."
	fi
	if "$TUI_CC" -O2 -o "$RADIN_HOME/bin/radin-cbm-json" \
		"$RADIN_HOME/lib/radin-cbm-json.c" >"$CC_LOG" 2>&1; then
		ok "radin-cbm-json built."
	else
		tail -n 20 "$CC_LOG" >&2
		warn "radin-cbm-json failed to build -- radin cbm-config is unavailable;"
		warn "the merge-only wiring is used instead."
	fi
	rm -f "$CC_LOG"
else
	warn "no C compiler found -- skipping the TUI. Use \`radin backlog show\`."
fi
ok "skills installed"

install_tool() {
	local name="$1" install_cmd="$2"
	# codebase-memory-mcp's installer targets ~/.local/bin, which is not on
	# PATH in every shell.
	if [ -n "$UPDATE" ] && { command -v "$name" || [ -x "$HOME/.local/bin/$name" ]; } >/dev/null 2>&1; then
		ok "$name already installed."
		return
	fi
	# Companion installs are advisory: a failed one warns, never aborts radin's
	# own install (set -e would otherwise kill the script here). Their output
	# is noise on success (pip dependency walls, brew hints) -- log it, show
	# the tail only when the install fails.
	if [ -n "$VERBOSE" ]; then
		if eval "$install_cmd" </dev/null; then
			ok "$name installed."
		else
			warn "$name install failed -- radin itself is unaffected."
		fi
		return
	fi
	local log
	log="$(mktemp)"
	if eval "$install_cmd" >"$log" 2>&1 </dev/null; then
		ok "$name installed."
	else
		tail -n 20 "$log" >&2
		warn "$name install failed -- radin itself is unaffected."
	fi
	rm -f "$log"
}

# Prints `enabled` or `disabled` for plugin $1's user-scope install, nothing
# when it has none. A project-scope install does not count: its hooks run in
# that one project only. ponytail: second copy in lib/radin-doctor.sh.
plugin_state() {
	claude plugin list 2>/dev/null | awk -v id="$1" '
		/❯ / { cur = ($2 == id); scope = ""; next }
		cur && /Scope:/ { scope = $2 }
		cur && scope == "user" && /Status:/ { state = /disabled/ ? "disabled" : "enabled" }
		END { if (state) print state }
	'
}

install_plugin() {
	local name="$1" plugin_id="$2"
	# Plugins install through the `claude` CLI and nothing else, so on a machine
	# without it say so once per plugin instead of asking and then failing.
	if ! command -v claude >/dev/null 2>&1; then
		warn "$name skipped: the 'claude' CLI is not on PATH. Install Claude Code, then re-run install.sh."
		return 0
	fi
	install_plugin_files "$@"
	# A plugin's hooks run only while it is enabled, and radin's execution
	# prompt relies on ponytail's SubagentStart hook.
	[ "$(plugin_state "$plugin_id")" = disabled ] || return 0
	claude plugin enable --scope user "$plugin_id" >/dev/null 2>&1 </dev/null || true
	[ "$(plugin_state "$plugin_id")" = enabled ] ||
		warn "$name is installed but disabled, so its hooks do not run. Run: claude plugin enable --scope user $plugin_id"
}

install_plugin_files() {
	local name="$1" plugin_id="$2" marketplace_source="$3"
	if [ -n "$UPDATE" ] && [ -n "$(plugin_state "$plugin_id")" ]; then
		ok "$name already installed."
		return
	fi
	if [ -n "$(plugin_state "$plugin_id")" ]; then
		if [ -n "$VERBOSE" ]; then
			if {
				claude plugin marketplace update
				claude plugin update "$plugin_id"
			} </dev/null; then
				ok "$name updated."
			else
				warn "$name update failed -- radin itself is unaffected."
			fi
			return
		fi
		local log
		log="$(mktemp)"
		if {
			claude plugin marketplace update
			claude plugin update "$plugin_id"
		} >"$log" 2>&1 </dev/null; then
			ok "$name updated."
		else
			tail -n 20 "$log" >&2
			warn "$name update failed -- radin itself is unaffected."
		fi
		rm -f "$log"
		return
	fi
	if [ -n "$VERBOSE" ]; then
		if {
			claude plugin marketplace add "$marketplace_source"
			claude plugin install "$plugin_id"
		} </dev/null; then
			ok "$name installed."
		else
			warn "$name install failed -- radin itself is unaffected."
		fi
		return
	fi
	local log
	log="$(mktemp)"
	if {
		claude plugin marketplace add "$marketplace_source"
		claude plugin install "$plugin_id"
	} >"$log" 2>&1 </dev/null; then
		ok "$name installed."
	else
		tail -n 20 "$log" >&2
		warn "$name install failed -- radin itself is unaffected."
	fi
	rm -f "$log"
}

# Every sub-agent role ships a distinct RADIN_MODEL_<ROLE> token instead of a
# model name, so no model is forced. Roles share a model by group: major for
# planning, execution, review and debug; minor for fact-finding and low-complexity tasks.
MODEL_MAJOR="sonnet"
# Fact-finding retrieves a checkable fact and its prompt requires the evidence
# that establishes it, so the router can reject a wrong answer. A task the
# planner marked `complexity low` needs no design judgement, and a wrong one
# still meets the dirty-tree check and Phase 6's review. Both take the cheapest tier.
MODEL_MINOR="haiku"
# Effort stays unset: the Agent tool picks the model's default. No install question sets it.
EFFORT_MAJOR=""
EFFORT_MINOR=""

# A file with no token is a no-op, so every pass runs over every SKILL.md and
# lib/*.md and keeps no list of its own.
shipped_text_files() {
	local s f
	for s in $SHIPPED_SKILLS; do printf '%s\n' "$(host_skills_dir "$1")/$s/SKILL.md"; done
	for f in $SHIPPED_HOSTLIB; do printf '%s\n' "$RADIN_HOME/hosts/$1/lib/$f"; done
}

# Quoted JSON array body of a space-separated name list.
json_names() {
	local n sep=""
	for n in $1; do
		printf '%s"%s"' "$sep" "$n"
		sep=", "
	done
}

set_role_models() {
	# No `sed -i`: BSD sed (macOS) and GNU sed (Linux) take incompatible forms
	# of it. Temp-file-plus-mv avoids the divergence entirely.
	local file="$1" tmp
	tmp="$(mktemp)"
	sed -e "s/RADIN_MODEL_PLANNING/${MODEL_MAJOR}/g" \
		-e "s/RADIN_MODEL_EXECUTION/${MODEL_MAJOR}/g" \
		-e "s/RADIN_MODEL_REVIEW/${MODEL_MAJOR}/g" \
		-e "s/RADIN_MODEL_DEBUG/${MODEL_MAJOR}/g" \
		-e "s/RADIN_MODEL_FACTFIND/${MODEL_MINOR}/g" \
		-e "s/RADIN_MODEL_LOW/${MODEL_MINOR}/g" \
		"$file" >"$tmp" && mv "$tmp" "$file"
	# A surviving token reaches the model as a literal model name and every
	# dispatch fails -- louder to stop here than to debug that.
	if grep -q 'RADIN_MODEL_' "$file"; then
		printf "%b\n" "${RED}${RAT} failed to write the sub-agent models into $file.${RESET} Re-run the installer." >&2
		exit 1
	fi
}

set_role_efforts() {
	local file="$1" tmp
	tmp="$(mktemp)"
	sed -e "s/RADIN_EFFORT_PLANNING/${EFFORT_MAJOR}/g" \
		-e "s/RADIN_EFFORT_EXECUTION/${EFFORT_MAJOR}/g" \
		-e "s/RADIN_EFFORT_REVIEW/${EFFORT_MAJOR}/g" \
		-e "s/RADIN_EFFORT_DEBUG/${EFFORT_MAJOR}/g" \
		-e "s/RADIN_EFFORT_FACTFIND/${EFFORT_MINOR}/g" \
		-e "s/RADIN_EFFORT_LOW/${EFFORT_MINOR}/g" \
		"$file" >"$tmp" && mv "$tmp" "$file"
	# A surviving token reaches the Agent call as a literal effort and the
	# dispatch fails.
	if grep -q 'RADIN_EFFORT_' "$file"; then
		printf "%b\n" "${RED}${RAT} failed to write the sub-agent efforts into $file.${RESET} Re-run the installer." >&2
		exit 1
	fi
}

# Skills carry a RADIN_CLI token instead of a hardcoded invocation -- same
# contract as RADIN_MODEL_<ROLE>. set_cli writes in either the bare `radin`
# (symlinked onto PATH below) or the full dispatcher path, so no skill knows
# which the user picked.
set_cli() {
	local file="$1" cli="$2" tmp
	tmp="$(mktemp)"
	sed 's|RADIN_CLI|'"$cli"'|g' "$file" >"$tmp" && mv "$tmp" "$file"
	# A surviving token reaches the model as a literal command and every CLI
	# call fails -- louder to stop here than to debug that.
	if grep -q 'RADIN_CLI' "$file"; then
		printf "%b\n" "${RED}${RAT} failed to write the CLI invocation into $file.${RESET} Re-run the installer." >&2
		exit 1
	fi
}

# Skills carry a RADIN_LIB token instead of a literal `$HOME` path
# -- same contract as RADIN_CLI. The Read tool needs an absolute path, so a
# literal `$HOME` would leave the model expanding it before every on-demand
# doc read.
set_lib() {
	local file="$1" lib="$2" tmp
	tmp="$(mktemp)"
	sed 's|RADIN_LIB|'"$lib"'|g' "$file" >"$tmp" && mv "$tmp" "$file"
	# A surviving token reaches the model as a literal path and every on-demand
	# doc read fails -- louder to stop here than to debug that.
	if grep -q 'RADIN_LIB' "$file"; then
		printf "%b\n" "${RED}${RAT} failed to write the lib path into $file.${RESET} Re-run the installer." >&2
		exit 1
	fi
}

AGENTS_RENDER_ERR=""
stage_agents_file() {
	AGENTS_RENDER_ERR="$("$RADIN_ROOT/scripts/render-host.sh" "$1" agents 2>&1 >"$2")" && return 0
	AGENTS_RENDER_ERR="${AGENTS_RENDER_ERR:-$1: render failed}"
	return 1
}

stage_agents_tree() {
	local f s
	mkdir -p "$1/lib"
	for f in $SHIPPED_HOSTLIB; do
		stage_agents_file "$RADIN_ROOT/lib/$f" "$1/lib/$f" || return 1
	done
	for s in $SHIPPED_SKILLS; do
		cp -r "$RADIN_ROOT/skills/$s" "$1/"
		stage_agents_file "$RADIN_ROOT/skills/$s/SKILL.md" "$1/$s/SKILL.md" || return 1
	done
}

# Companion steps for Codex and opencode belong here. A missing CLI never fails the run.
install_host_companions() {
	local cli
	cli="$(host_field "$1" 4)"
	command -v "$cli" >/dev/null 2>&1 ||
		warn "$cli CLI not found: radin's own files are installed, companion steps skipped"
}

# Renders into a stage dir first, so one bad file leaves Codex and opencode out
# and writes nothing, while the other hosts go on.
install_agents_render() {
	local id stage f s keep=""
	case " $RENDERS " in *" agents "*) ;; *) return 0 ;; esac
	stage="$(mktemp -d)"
	if stage_agents_tree "$stage"; then
		while IFS= read -r f; do
			set_cli "$f" "$RADIN_CLI_VALUE"
			set_lib "$f" "$RADIN_HOME/hosts/agents/lib"
		done < <(find "$stage" -type f -name '*.md')
		# The agents prompts print no model or effort line; a token left over is a render bug.
		if grep -rqE 'RADIN_(MODEL|EFFORT)_' "$stage"; then
			AGENTS_RENDER_ERR="$(grep -rlE 'RADIN_(MODEL|EFFORT)_' "$stage" | head -1): model or effort token survives"
		fi
	fi
	if [ -z "$AGENTS_RENDER_ERR" ]; then
		mkdir -p "$RADIN_HOME/hosts/agents/lib" "$HOME/.agents/skills"
		for f in $SHIPPED_HOSTLIB; do
			cp "$stage/lib/$f" "$RADIN_HOME/hosts/agents/lib/"
		done
		for s in $SHIPPED_SKILLS; do
			cp -r "$stage/$s" "$HOME/.agents/skills/"
		done
		ok "agents render installed to ${BOLD}$HOME/.agents/skills${RESET}"
		for id in $SELECTED; do
			[ "$(host_field "$id" 3)" != agents ] || install_host_companions "$id"
		done
	else
		warn "agents render failed: $AGENTS_RENDER_ERR"
		warn "Codex and opencode are left out of this install."
		for id in $SELECTED; do
			[ "$(host_field "$id" 3)" = agents ] || keep="$keep $id"
		done
		SELECTED="${keep# }"
		set_renders
	fi
	rm -rf "$stage"
}

step "Sub-agent models"
# radin-batch is a skill running in the user's own thread, so its own model
# is whatever they picked with /model. Only its leaf sub-agents get a choice.
# The Agent tool takes a family alias, never a version: Claude Code resolves
# it to that family's current model.
MODELS="fable opus sonnet haiku"
SONNET_INDEX=3
HAIKU_INDEX=4
if [ -n "$UPDATE" ]; then
	# An update keeps the recorded answer instead of asking again.
	MODEL_MAJOR="$(manifest_value model_planning)"
	MODEL_MAJOR="${MODEL_MAJOR:-sonnet}"
	MODEL_MINOR="$(manifest_value model_factfind)"
	MODEL_MINOR="${MODEL_MINOR:-haiku}"
	ok "keeping sub-agent models: $MODEL_MAJOR, $MODEL_MINOR for fact-finding and low-complexity tasks"
elif ! host_selected claude; then
	:
elif prompt_yn "Choose radin-batch's sub-agent models? (defaults: sonnet, haiku for fact-finding and low-complexity tasks)"; then
	# shellcheck disable=SC2086  # word splitting is the point -- one arg per model
	MODEL_MAJOR="$(prompt_pick "planning, execution, review and debug sub-agents" "$SONNET_INDEX" $MODELS)"
	# shellcheck disable=SC2086
	MODEL_MINOR="$(prompt_pick "fact-finding and low-complexity sub-agents" "$HAIKU_INDEX" $MODELS)"
	ok "sub-agent models: $MODEL_MAJOR, $MODEL_MINOR for fact-finding and low-complexity tasks"
else
	ok "keeping default sub-agent models (sonnet; haiku for fact-finding and low-complexity tasks)"
fi
if host_selected claude; then
	for f in $(shipped_text_files claude); do
		tmp="$(mktemp)"
		if "$RADIN_ROOT/scripts/render-host.sh" "$f" claude >"$tmp"; then
			mv "$tmp" "$f"
		else
			rm -f "$tmp"
			printf "%b\n" "${RED}${RAT} could not render $f for claude${RESET}" >&2
			exit 1
		fi
		set_role_models "$f"
	done
fi

step "radin CLI on PATH"
# One `radin <backlog|state|scope|hooks|repair|doctor|uninstall>`
# command instead of long lib paths in every Bash call. The dispatcher always
# lands in ~/.radin/bin; this only symlinks it into ~/.local/bin.
# Never overwrites: an existing non-radin `radin` there is named and left
# alone, and skills then fall back to the full dispatcher path.
CLI_ON_PATH="false"
# Skills get whichever invocation actually works here: bare `radin` only when
# the symlink exists AND ~/.local/bin is on PATH; the full dispatcher path
# otherwise. Written into the RADIN_CLI token by set_cli below.
# shellcheck disable=SC2016  # $HOME must stay literal in the installed file
RADIN_CLI_VALUE='"$HOME/.radin/bin/radin"'
CLI_TARGET="$RADIN_HOME/bin/radin"
CLI_LINK="$HOME/.local/bin/radin"
CLI_LINK_NOW="$(readlink "$CLI_LINK" 2>/dev/null || true)"
if [ -e "$CLI_LINK" ] && [ "$CLI_LINK_NOW" != "$CLI_TARGET" ] && [ "$CLI_LINK_NOW" != "$HOME/.claude/.radin/bin/radin" ]; then
	warn "$CLI_LINK exists and isn't radin's -- leaving it alone; skills use the full path."
else
	mkdir -p "$HOME/.local/bin"
	ln -sf "$CLI_TARGET" "$CLI_LINK"
	CLI_ON_PATH="true"
	ok "radin CLI linked at ${BOLD}$CLI_LINK${RESET}"
	case ":$PATH:" in
	*":$HOME/.local/bin:"*)
		RADIN_CLI_VALUE='radin'
		;;
	*)
		warn "\$HOME/.local/bin is not on your PATH -- skills use the full path until it is."
		;;
	esac
fi
if host_selected claude; then
	for f in $(shipped_text_files claude); do
		set_cli "$f" "$RADIN_CLI_VALUE"
		set_lib "$f" "$RADIN_HOME/hosts/claude/lib"
	done
fi
install_agents_render

step "Agent guidance"
# A short section in ~/.claude/CLAUDE.md telling Claude when to reach for
# radin's skills (same pattern codebase-memory-mcp uses). Kept between
# radin:begin/end markers: a re-run rewrites only that block, everything
# outside them passes through untouched -- which is what makes writing it
# unconditionally safe on a file radin doesn't own.
CLAUDE_MD_GUIDANCE="false"
if host_selected claude; then
	CLAUDE_MD_GUIDANCE="true"
	# shellcheck disable=SC2016  # backticks here are markdown code spans, not command substitution
	RADIN_GUIDANCE='<!-- radin:begin -->
## radin

radin keeps a per-repo backlog in `<repo-root>/.claude/.radin/` so tasks
survive past one conversation. Reach for it instead of ad-hoc task tracking:

- A bug, idea, or follow-up comes up mid-session: record it with `/radin-record`.
- The user asks what is pending: run `'"$RADIN_CLI_VALUE"' backlog show` and print its output. One entry needs a plan first: `/radin-plan`.
- The user wants the backlog worked through: `/radin-batch` (it plans the entries `/radin-record` flagged, then executes), or `/radin-do <prompt>` for one ad-hoc task. A code review whose findings should become tasks: `/radin-review`.
- The user asks to mark a task done by hand: run `'"$RADIN_CLI_VALUE"' state task-done <id> <commit-hash>` (hash from `git rev-parse --short=12 HEAD`). `backlog --help` and `state --help` list every verb.
- Never hand-edit files under `.claude/.radin/` -- every backlog operation goes through the `'"$RADIN_CLI_VALUE"' backlog` CLI.
- Never guess on a broad or ambiguous ask: invoke `/mattpocock-skills:grilling` and let the user settle it before radin writes anything.
<!-- radin:end -->'
	CLAUDE_MD="$HOME/.claude/CLAUDE.md"
	touch "$CLAUDE_MD"
	GUIDANCE_TMP="$(mktemp)"
	# Strip any previous radin block, then append the current one -- idempotent
	# across re-runs. The second awk drops the blank lines the strip leaves at the
	# end (interior ones are held and reprinted), so a re-run stops growing the
	# file by one newline each time.
	awk '/^<!-- radin:begin -->$/ { skip = 1 } !skip { print } /^<!-- radin:end -->$/ { skip = 0 }' \
		"$CLAUDE_MD" |
		awk 'NF { while (pending-- > 0) print ""; pending = 0; print; next } { pending++ }' \
			>"$GUIDANCE_TMP"
	[ ! -s "$GUIDANCE_TMP" ] || printf '\n' >>"$GUIDANCE_TMP"
	printf '%s\n' "$RADIN_GUIDANCE" >>"$GUIDANCE_TMP"
	mv "$GUIDANCE_TMP" "$CLAUDE_MD"
	ok "radin section written to ${BOLD}$CLAUDE_MD${RESET} (between radin:begin/end markers)"
fi

# Its own installer's default target isn't on PATH in every shell, so resolve
# the just-installed binary by path too.
cbm_bin() {
	local bin
	bin="$(command -v codebase-memory-mcp || true)"
	[ -n "$bin" ] || bin="$HOME/.local/bin/codebase-memory-mcp"
	[ -x "$bin" ] || return 1
	printf '%s' "$bin"
}

step "Companion tools"
THERMO_SKILL="$HOME/.claude/skills/thermo-nuclear/SKILL.md"
if host_selected claude; then
	if [ -n "$UPDATE" ] && [ -f "$THERMO_SKILL" ]; then
		ok "thermo-nuclear already installed."
	else
		# thermo-nuclear is vendored via the vercel-labs/skills CLI (agentskills.io
		# spec), not a Claude Code plugin -- cursor/plugins isn't a plugin marketplace
		# repo, just a SKILL.md at this subpath. Falls back to a raw curl of the file
		# if npx isn't available.
		if command -v npx >/dev/null 2>&1; then
			NPX_LOG="$(mktemp)"
			# </dev/null everywhere below: under `curl | bash` fd0 is the script itself,
			# and a child that reads stdin eats the rest of it -- the install then just
			# stops, silently, before the questions.
			if ! eval "$THERMO_INSTALL_CMD" >"$NPX_LOG" 2>&1 </dev/null; then
				cat "$NPX_LOG" >&2
				rm -f "$NPX_LOG"
				exit 1
			fi
			rm -f "$NPX_LOG"
			# Renamed back to "thermo-nuclear" -- every radin agent/skill invokes it
			# under that name, and skills CLI installs use the source folder's name.
			# A rerun where the CLI kept an existing install writes no source folder,
			# so guard the move instead of letting set -e abort the install there.
			if [ -d "$HOME/.claude/skills/thermo-nuclear-code-quality-review" ]; then
				rm -rf "$HOME/.claude/skills/thermo-nuclear"
				mv "$HOME/.claude/skills/thermo-nuclear-code-quality-review" "$HOME/.claude/skills/thermo-nuclear"
			fi
		else
			warn "npx not found -- falling back to a direct SKILL.md download for thermo-nuclear."
			mkdir -p "$HOME/.claude/skills/thermo-nuclear"
			curl -fsSL "https://raw.githubusercontent.com/cursor/plugins/refs/heads/main/cursor-team-kit/skills/thermo-nuclear-code-quality-review/SKILL.md" \
				-o "$HOME/.claude/skills/thermo-nuclear/SKILL.md"
		fi
		ok "thermo-nuclear installed."
	fi
	# Strip disable-model-invocation so radin-review can invoke thermo-nuclear as
	# a sub-skill; upstream sets it to block direct end-user invocation, which
	# also blocks our own agent-to-skill call. sed -i differs BSD/GNU -- write to
	# temp then mv, portable across both.
	if [ -f "$THERMO_SKILL" ]; then
		THERMO_TMP="$(mktemp)"
		grep -v '^disable-model-invocation:' "$THERMO_SKILL" >"$THERMO_TMP"
		mv "$THERMO_TMP" "$THERMO_SKILL"
	fi
fi

# unslop and technical-writing: two pstack skills fetched straight from
# cursor/plugins `main`, deliberately unpinned so users get upstream edits.
# Every run (update included) refetches, because `radin update` is the only way
# they arrive. A skill directory radin did not install is never touched; a
# failed or non-frontmatter download keeps the previous copy. Advisory.
PSTACK_OWNED=""
install_pstack_skill() {
	local name="$1" dir="$HOME/.claude/skills/$1" tmp mine=""
	[ "$(manifest_value "$name")" = true ] && mine=1
	if [ -d "$dir" ] && [ -z "$mine" ]; then
		warn "$name skipped: $dir exists and radin did not install it."
		return 0
	fi
	tmp="$(mktemp)"
	if curl -fsSL "$PSTACK_RAW/$name/SKILL.md" -o "$tmp" </dev/null 2>/dev/null &&
		[ "$(head -c 3 "$tmp")" = "---" ]; then
		mkdir -p "$dir"
		# Same strip as thermo-nuclear: upstream's disable-model-invocation also
		# blocks radin's own sub-agents.
		grep -v '^disable-model-invocation:' "$tmp" >"$dir/SKILL.md"
		ok "$name installed."
		PSTACK_OWNED="$PSTACK_OWNED $name "
	else
		warn "$name download failed -- radin itself is unaffected."
		[ -n "$mine" ] && [ -f "$dir/SKILL.md" ] && PSTACK_OWNED="$PSTACK_OWNED $name "
	fi
	rm -f "$tmp"
	return 0
}
if host_selected claude; then
	install_pstack_skill unslop
	install_pstack_skill technical-writing
else
	# Without the claude host these two are not refetched; keep the ownership record.
	for n in unslop technical-writing; do
		[ "$(manifest_value "$n")" != true ] || PSTACK_OWNED="$PSTACK_OWNED $n "
	done
fi

# rtk ships in more than one package manager. Installing it with brew on a
# mise-managed machine leaves behind a manager the user never chose, so the
# one question here is which manager to install through. `curl` keeps rtk's
# own upstream installer.
# An update keeps the recorded answer instead of asking again.
PKG_MGR=""
[ -z "$UPDATE" ] || PKG_MGR="$(manifest_value package_manager)"
PKG_CHOICES=""
[ -n "$BREW" ] && PKG_CHOICES="$PKG_CHOICES brew"
[ -n "$MISE" ] && PKG_CHOICES="$PKG_CHOICES mise"
if [ -n "$PKG_MGR" ]; then
	:
elif [ -n "$PKG_CHOICES" ]; then
	# shellcheck disable=SC2086  # word splitting is the point -- one arg per manager
	PKG_MGR="$(prompt_pick "install rtk through" 1 $PKG_CHOICES "curl")"
else
	PKG_MGR="curl"
fi
# Neither manager is asked for codebase-memory-mcp -- its own installer
# resolves OS/arch and verifies checksums, which radin doesn't reimplement.
RTK_INSTALL_CMD="$(rtk_cmd "$PKG_MGR")"
install_tool "rtk" "$RTK_INSTALL_CMD"

# codebase-memory-mcp ships one static binary and its own installer resolves
# OS/arch and verifies checksums, so radin delegates instead of reimplementing
# that (same reasoning as rtk's fallback). `--skip-config` is not optional
# here: without it, upstream writes MCP entries, a skill, three agent
# definitions and SessionStart/SubagentStart/PreToolUse hooks into ~/.claude
# across 45 client surfaces. radin owns every ~/.claude write, and
# `radin hooks` does the two it wants, merge-only.
install_tool "codebase-memory-mcp" "$CBM_INSTALL_CMD"

if host_selected claude; then
	# caveman ships as a Claude Code plugin (not an npm package) -- installs via
	# the plugin marketplace flow, same as the interactive `/plugin` command.
	install_plugin "caveman" "caveman@caveman" "JuliusBrussee/caveman"

	# ponytail ships as a Claude Code plugin too -- same marketplace flow.
	install_plugin "ponytail" "ponytail@ponytail" "DietrichGebert/ponytail"
	# ponytail shows a band above the prompt unless this flag says "off". Write it
	# only when absent, so a band the user turned on by hand stays on until reinstall.
	[ -e "$HOME/.claude/.ponytail-band" ] || {
		mkdir -p "$HOME/.claude" && printf 'off' >"$HOME/.claude/.ponytail-band"
	}

	# mattpocock-skills ships from Anthropic's own official marketplace, not a
	# third-party repo. radin-plan invokes its /grilling and /research skills
	# rather than reimplementing an interview loop or a research step.
	install_plugin "mattpocock-skills" "mattpocock-skills@claude-plugins-official" "anthropics/claude-plugins-official"
fi

CBM_AGENT_CONFIG="false"
if host_selected claude && CBM_BIN="$(cbm_bin)"; then
	# auto_index is off upstream, which leaves a wired session querying an empty
	# graph until someone indexes by hand. Idempotent, so it also fixes an
	# install that predates this line.
	if ! "$CBM_BIN" config set auto_index true >/dev/null 2>&1; then
		warn "could not enable codebase-memory-mcp auto-index -- run: codebase-memory-mcp config set auto_index true"
	fi

	# The whole tool: binary, then upstream's own Claude Code configuration (its
	# skill, three graph agents, user-scope MCP entry, and the hooks that route
	# Grep/Glob to the graph).
	# This step wraps that write because upstream #1200 (open through v0.11.0)
	# replaces the whole SessionStart array in settings.json instead of
	# merging: it snapshots first, runs their installer, then puts back every
	# pre-existing hook and MCP entry the write dropped. Their entries stay,
	# yours come back, and `codebase-memory-mcp update` can be followed by
	# `radin repair` for the same reason -- the caller names no companion.
	if [ -x "$RADIN_HOME/bin/radin-cbm-json" ]; then
		# Same contract as install_tool: the per-item trace (SNAPSHOT/STASHED/
		# RESTORED/INTACT/CBM, and upstream's own 45-client inventory on a
		# failed run) is what a failure needs and noise on success, so it all
		# stays in one log and never reaches the terminal. Its own exit code
		# only says whether the graph came out wired: a PARTIAL run exits 0,
		# so read that back out of the log rather than claiming success.
		CBM_LOG="$RADIN_HOME/cbm-config.log"
		if [ -n "$VERBOSE" ]; then
			bash "$RADIN_HOME/lib/radin-cbm-config.sh" install </dev/null 2>&1 | tee "$CBM_LOG"
			CBM_STATUS="${PIPESTATUS[0]}"
		else
			bash "$RADIN_HOME/lib/radin-cbm-config.sh" install >"$CBM_LOG" 2>&1 </dev/null
			CBM_STATUS="$?"
		fi
		if [ "$CBM_STATUS" = 0 ]; then
			CBM_AGENT_CONFIG="true"
			if grep -q '^PARTIAL ' "$CBM_LOG"; then
				warn "codebase-memory-mcp reported a failure while configuring Claude Code,"
				warn "but its hooks and MCP entry are in place. Details: ${BOLD}$CBM_LOG${RESET}"
			else
				ok "codebase-memory-mcp wired: skill, graph agents, hooks, user-scope MCP (every repo, no per-project step)."
			fi
			# Upstream writes no CLAUDE.md text, and a skill description alone
			# did not get agents to call the graph (25 calls in 402 sessions).
			bash "$RADIN_HOME/lib/radin-cbm-hooks.sh" claude-md || true
		else
			warn "codebase-memory-mcp configuration failed -- radin itself is unaffected."
			warn "Your own hooks were restored from the snapshot. Details: ${BOLD}$CBM_LOG${RESET}"
			info "Falling back to radin's merge-only wiring:"
			bash "$RADIN_HOME/lib/radin-cbm-hooks.sh" claude-md || true
			info "Then run "radin hooks mcp" in each repo for its .mcp.json entry."
		fi
	else
		# The restore step is the compiled JSON helper, and running upstream's
		# write without it is how a machine loses caveman's and ponytail's
		# SessionStart hooks. A smaller install beats a destructive write with
		# no restore behind it.
		warn "no C compiler -- skipping upstream's own Claude Code configuration:"
		warn "its write drops other tools' SessionStart hooks (#1200) and radin"
		warn "needs radin-cbm-json to put them back. Using the merge-only wiring."
		bash "$RADIN_HOME/lib/radin-cbm-hooks.sh" claude-md || true
		info "Then run "radin hooks mcp" in each repo for its .mcp.json entry."
	fi
fi

# Skills and leaves Read radin's own lib/*.md from outside the repo, which
# prompts on every read. One Read rule per spelling of ~/.radin in
# permissions.allow ends that; the uninstaller removes the same rules.
if host_selected claude; then
	if [ -x "$RADIN_HOME/bin/radin-cbm-json" ]; then
		if ! bash "$RADIN_HOME/lib/radin-cbm-config.sh" allow >/dev/null 2>&1 </dev/null; then
			warn "could not add the Read rule for ~/.radin to settings.json --"
			warn "Claude Code will ask before each read of radin's own files."
		elif [ -n "$MIGRATED$LEGACY_LEFT" ]; then
			bash "$RADIN_HOME/lib/radin-cbm-config.sh" unallow-legacy >/dev/null 2>&1 </dev/null ||
				warn "could not remove the old Read rule for ~/.claude/.radin from settings.json."
		fi
	else
		warn "no C compiler -- settings.json keeps no Read rule for ~/.radin,"
		warn "so Claude Code asks before each read of radin's own files."
	fi
fi

if host_selected claude; then
	for f in $(shipped_text_files claude); do
		set_role_efforts "$f"
	done
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
json_bool_pstack() {
	case "$PSTACK_OWNED" in
	*" $1 "*) printf 'true' ;;
	*) printf 'false' ;;
	esac
}
json_bool_plugin() {
	if command -v claude >/dev/null 2>&1 && [ "$(plugin_state "$1")" = enabled ]; then
		printf 'true'
	else
		printf 'false'
	fi
}

# macOS ships shasum only; Linux ships sha256sum.
sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | cut -d' ' -f1
	else
		shasum -a 256 "$1" | cut -d' ' -f1
	fi
}
# One entry per line, keyed by the path under $HOME. Taken last, so each digest matches the final bytes.
json_files() {
	local p sep=""
	while IFS= read -r p; do
		printf '%s\n    "%s": "%s"' "$sep" "${p#"$HOME"/}" "$(sha256_of "$p")"
		sep=","
	done < <(owned_paths)
}
AGENTS_CLIS=""
for id in $SELECTED; do
	[ "$(host_field "$id" 3)" != agents ] || AGENTS_CLIS="$AGENTS_CLIS $(host_field "$id" 4)"
done

mkdir -p "$RADIN_HOME"
# `radin update` reads this to decide between `git pull` in a dev clone and a
# fresh tarball download.
printf '%s\n' "$RADIN_ROOT" >"$RADIN_HOME/install_root"
INSTALLED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat >"$MANIFEST_FILE" <<EOF
{
  "manifest_version": 2,
  "version": "$MANIFEST_VERSION",
  "installed_at": "$INSTALLED_AT",
  "package_manager": "$PKG_MGR",
  "install_root": "$RADIN_ROOT",
  "model_planning": "$MODEL_MAJOR",
  "model_execution": "$MODEL_MAJOR",
  "model_review": "$MODEL_MAJOR",
  "model_debug": "$MODEL_MAJOR",
  "model_factfind": "$MODEL_MINOR",
  "model_low": "$MODEL_MINOR",
  "effort_planning": "$EFFORT_MAJOR",
  "effort_execution": "$EFFORT_MAJOR",
  "effort_review": "$EFFORT_MAJOR",
  "effort_debug": "$EFFORT_MAJOR",
  "effort_factfind": "$EFFORT_MINOR",
  "effort_low": "$EFFORT_MINOR",
  "claude_md_guidance": $CLAUDE_MD_GUIDANCE,
  "cbm_agent_config": $CBM_AGENT_CONFIG,
  "cli_on_path": $CLI_ON_PATH,
  "hosts": [$(json_names "$SELECTED")],
  "agents_clis": [$(json_names "$AGENTS_CLIS")],
  "skills": [$(json_names "$SHIPPED_SKILLS thermo-nuclear")],
  "lib": [$(json_names "$SHIPPED_LIB")],
  "hostlib": [$(json_names "$SHIPPED_HOSTLIB")],
  "companion_tools": {
    "rtk": $(json_bool_cmd rtk),
    "codebase-memory-mcp": $(cbm_bin >/dev/null 2>&1 && printf 'true' || printf 'false'),
    "caveman": $(json_bool_plugin "caveman@caveman"),
    "ponytail": $(json_bool_plugin "ponytail@ponytail"),
    "mattpocock-skills": $(json_bool_plugin "mattpocock-skills@claude-plugins-official"),
    "unslop": $(json_bool_pstack unslop),
    "technical-writing": $(json_bool_pstack technical-writing)
  },
  "files": {$(json_files)
  }
}
EOF
ok "manifest written to ${BOLD}$MANIFEST_FILE${RESET}"

step "Done"
INSTALL_DONE="1"
if [ -n "$UPDATE" ]; then
	ok "radin updated. ${DIM}Go be stingy with those tokens.${RESET}"
else
	ok "radin installed. ${DIM}Go be stingy with those tokens.${RESET}"
	info "Open Claude Code in a repo and run ${BOLD}/radin-record${RESET} to file your first"
	info "task, then ${BOLD}/radin-batch${RESET} to work the backlog. ${BOLD}radin${RESET} opens the TUI."
fi
[ -z "$MIGRATED" ] || warn "restart open Claude sessions: they hold the old path"
info "${BOLD}radin doctor${RESET} checks this install · ${BOLD}radin update${RESET} updates radin itself."
