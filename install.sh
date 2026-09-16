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
UPDATE=""
for arg in "$@"; do
	[ "$arg" = "--force" ] && FORCE="1"
	[ "$arg" = "--yes" ] && YES="1"
	# --update is what `radin update` runs: every companion tool updates, and
	# no behaviour question is asked again -- the answers come from the
	# manifest the last install wrote.
	if [ "$arg" = "--update" ]; then
		UPDATE="1"
		FORCE="1"
		YES="1"
	fi
done

MANIFEST_FILE="$HOME/.claude/.radin/manifest.json"
# Flat `"key": value` lookup in the previous manifest. Prints nothing for a
# missing key, so every caller keeps its own default.
manifest_value() {
	[ -f "$MANIFEST_FILE" ] || return 0
	sed -n 's/.*"'"$1"'": *"\{0,1\}\([^",]*\)"\{0,1\}.*/\1/p' "$MANIFEST_FILE" | head -1
}

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

printf "%b\n" "${BOLD}${MAGENTA}"
printf "%s\n" "  🐀 radin — stingy on tokens, generous on backlog throughput"
printf "%b\n" "${RESET}${DIM}  Installs backlog-workflow skills into ~/.claude, plus the whole curated"
printf "%b\n\n" "  token-saving stack. Only execution behaviour is asked about.${RESET}"

# No `brew shellenv` eval: it prepends brew's bin to PATH and would shadow a
# version-manager python3 (mise/pyenv) with brew's -- probing the wrong
# interpreter in the pyexpat preflight below. brew itself is called via $BREW.
BREW="$(command -v brew || true)"

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
		if [ -d "$dir/skills" ] && [ -d "$dir/lib" ]; then
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

step "Installing skills into ~/.claude"
mkdir -p "$HOME/.claude/skills" "$HOME/.claude/.radin/lib"
# Explicit name lists, not lib/* or skills/* globs: install.sh may only copy
# files radin itself named (AGENTS.md Constraints), and a stray file in a dev
# clone must not ship.
for f in radin-namespace.sh radin-json.sh radin-backlog.sh radin-tui.c \
	radin-cbm-json.c radin-state.sh \
	radin-scope.sh radin-prioritization.md radin-execute-prompts.md \
	radin-execute-recovery.md radin-execute-reporting.md \
	radin-execute-clarify.md radin-execute-session.md \
	radin-execute-resume.md radin-cbm-hooks.sh \
	radin-cbm-config.sh radin-update.sh \
	radin-doctor.sh radin-uninstall.sh; do
	cp "$RADIN_ROOT/lib/$f" "$HOME/.claude/.radin/lib/"
done
for s in radin-execute radin-review radin-record radin-show radin-plan \
	radin-setup-hooks radin-stats radin-doctor radin-uninstall; do
	cp -r "$RADIN_ROOT/skills/$s" "$HOME/.claude/skills/"
done
mkdir -p "$HOME/.claude/.radin/bin"
cp "$RADIN_ROOT/bin/radin" "$HOME/.claude/.radin/bin/"
chmod +x "$HOME/.claude/.radin/bin/radin"

# The TUI and the cbm-config JSON helper are C, so they are the two files
# built here rather than copied. Advisory like a companion tool: a box with no
# compiler keeps every other subcommand -- `radin backlog show` covers the
# reading the TUI does, and `radin cbm-hooks all` covers the merge-only wiring
# `radin cbm-config` would have done.
TUI_CC="$(command -v cc || command -v gcc || command -v clang || true)"
if [ -n "$TUI_CC" ]; then
	CC_LOG="$(mktemp)"
	if "$TUI_CC" -O2 -o "$HOME/.claude/.radin/bin/radin-tui" \
		"$HOME/.claude/.radin/lib/radin-tui.c" >"$CC_LOG" 2>&1; then
		ok "radin tui built."
	else
		tail -n 20 "$CC_LOG" >&2
		warn "radin tui failed to build -- every other subcommand still works."
	fi
	if "$TUI_CC" -O2 -o "$HOME/.claude/.radin/bin/radin-cbm-json" \
		"$HOME/.claude/.radin/lib/radin-cbm-json.c" >"$CC_LOG" 2>&1; then
		ok "radin-cbm-json built."
	else
		tail -n 20 "$CC_LOG" >&2
		warn "radin-cbm-json failed to build -- radin cbm-config is unavailable;"
		warn "the merge-only wiring is used instead."
	fi
	rm -f "$CC_LOG"
else
	warn "no C compiler found -- skipping radin tui. Use \`radin backlog show\`."
fi
# thermo-nuclear is vendored via the vercel-labs/skills CLI (agentskills.io
# spec), not a Claude Code plugin -- cursor/plugins isn't a plugin marketplace
# repo, just a SKILL.md at this subpath. Falls back to a raw curl of the file
# if npx isn't available.
if command -v npx >/dev/null 2>&1; then
	NPX_LOG="$(mktemp)"
	# </dev/null everywhere below: under `curl | bash` fd0 is the script itself,
	# and a child that reads stdin eats the rest of it -- the install then just
	# stops, silently, before the questions.
	if ! npx -y skills add "https://github.com/cursor/plugins/tree/main/cursor-team-kit/skills/thermo-nuclear-code-quality-review" -g -a claude-code -y >"$NPX_LOG" 2>&1 </dev/null; then
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
ok "skills installed"

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

install_tool() {
	local name="$1" check_cmd="$2" install_cmd="$3"
	if command -v "$check_cmd" >/dev/null 2>&1 && [ -z "$FORCE" ]; then
		ok "$name already installed, skipping (--force to update)."
		return
	fi
	# Companion installs are advisory: a failed one warns, never aborts radin's
	# own install (set -e would otherwise kill the script here). Their output
	# is noise on success (pip dependency walls, brew hints) -- log it, show
	# the tail only when the install fails.
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

install_plugin() {
	local name="$1" plugin_id="$2" marketplace_source="$3"
	# Plugins install through the `claude` CLI and nothing else, so on a machine
	# without it say so once per plugin instead of asking and then failing.
	if ! command -v claude >/dev/null 2>&1; then
		warn "$name skipped: the 'claude' CLI is not on PATH. Install Claude Code, then re-run with --force."
		return 0
	fi
	if claude plugin list 2>/dev/null | grep -q "$plugin_id"; then
		if [ -z "$FORCE" ]; then
			ok "$name already installed, skipping (--force to update)."
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
# model name, so no model is forced and each role is set independently below.
MODEL_PLANNING="sonnet"
MODEL_EXECUTION="sonnet"
MODEL_REVIEW="sonnet"
MODEL_DEBUG="sonnet"
# Fact-finding retrieves a checkable fact and its prompt requires the evidence
# that establishes it, so the cheapest tier is the default: the router reads
# that evidence and can reject a wrong answer.
MODEL_FACTFIND="haiku"

set_role_models() {
	# No `sed -i`: BSD sed (macOS) and GNU sed (Linux) take incompatible forms
	# of it. Temp-file-plus-mv avoids the divergence entirely.
	local file="$1" tmp
	tmp="$(mktemp)"
	sed -e "s/RADIN_MODEL_PLANNING/${MODEL_PLANNING}/g" \
		-e "s/RADIN_MODEL_EXECUTION/${MODEL_EXECUTION}/g" \
		-e "s/RADIN_MODEL_REVIEW/${MODEL_REVIEW}/g" \
		-e "s/RADIN_MODEL_DEBUG/${MODEL_DEBUG}/g" \
		-e "s/RADIN_MODEL_FACTFIND/${MODEL_FACTFIND}/g" \
		"$file" >"$tmp" && mv "$tmp" "$file"
	# A surviving token reaches the model as a literal model name and every
	# dispatch fails -- louder to stop here than to debug that.
	if grep -q 'RADIN_MODEL_' "$file"; then
		printf "%b\n" "${RED}${RAT} failed to write the sub-agent models into $file.${RESET} Re-run the installer." >&2
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

# Skills carry a RADIN_LIB token instead of a literal `$HOME/.claude/.radin/lib`
# -- same contract as RADIN_CLI. The Read tool needs an absolute path, so a
# literal `$HOME` would leave the model expanding it before every on-demand
# doc read.
set_lib() {
	local file="$1" tmp
	tmp="$(mktemp)"
	sed 's|RADIN_LIB|'"$HOME/.claude/.radin/lib"'|g' "$file" >"$tmp" && mv "$tmp" "$file"
	# A surviving token reaches the model as a literal path and every on-demand
	# doc read fails -- louder to stop here than to debug that.
	if grep -q 'RADIN_LIB' "$file"; then
		printf "%b\n" "${RED}${RAT} failed to write the lib path into $file.${RESET} Re-run the installer." >&2
		exit 1
	fi
}

# The agent ships no concurrency rule of its own -- only a marker line. awk
# swaps that line for whichever rule the answer below picks, so the agent file
# never carries a variant the user didn't choose.
# shellcheck disable=SC2016  # backticks here are markdown code spans, not command substitution
SEQUENTIAL_RULE='- **One execution sub-agent at a time.** Dispatch one task, wait for its `STATUS:` line, finish its bookkeeping, then dispatch the next. Never put two `Task` calls in one message, however independent the tasks look. Batching other tool calls stays fine -- this rule is about `Task` only, and about execution sub-agents only: read-only dispatches stay parallel per Core Constraints.'
# shellcheck disable=SC2016  # backticks here are markdown code spans, not command substitution
PARALLEL_RULE='- **Concurrency allowed, and only under these conditions.** Several execution sub-agents may run in the same turn when they share no `depends_on` chain and no files, and only when Phase 0.5 recorded the worktree answer as yes -- parallel agents in one worktree corrupt each other commits. Worktree answer is no, or file overlap is at all unclear: dispatch strictly one at a time. Launch parallel ones in one message. Per-task steps stay unchanged, and each targets that task own tree, resolved for you by `radin-state.sh dirty-recover` -- its own dirty check, its own commit, its own `task-done`. Never check the shared checkout while another agent is in flight: you would stash a sibling task work out from under it.'

set_concurrency() {
	local file="$1" rule="$2" tmp
	tmp="$(mktemp)"
	awk -v rule="$rule" '/^<!-- radin:concurrency -->$/ { print rule; next } { print }' \
		"$file" >"$tmp" && mv "$tmp" "$file"
	# A surviving marker means the agent ships with no concurrency rule at all,
	# and the model then invents one -- louder to fail here than to debug that.
	if grep -q '^<!-- radin:concurrency -->$' "$file"; then
		printf "%b\n" "${RED}${RAT} failed to write the concurrency rule into $file.${RESET} Re-run the installer." >&2
		exit 1
	fi
}

step "Execution concurrency"
CONCURRENCY_ANSWER=""
if [ -n "$UPDATE" ]; then
	case "$(manifest_value parallel_execution)" in
	true) CONCURRENCY_ANSWER="parallel" ;;
	false) CONCURRENCY_ANSWER="sequential" ;;
	esac
	[ -n "$CONCURRENCY_ANSWER" ] && info "keeping the recorded answer: $CONCURRENCY_ANSWER"
fi
if [ -z "$CONCURRENCY_ANSWER" ]; then
	CONCURRENCY_ANSWER="$(prompt_pick "How should radin-execute run sub-agents? (parallel only ever applies to independent tasks)" 2 "parallel" "sequential")"
fi
if [ "$CONCURRENCY_ANSWER" = "parallel" ]; then
	PARALLEL_MODE="true"
	set_concurrency "$HOME/.claude/skills/radin-execute/SKILL.md" "$PARALLEL_RULE"
	ok "parallel execution allowed (independent tasks only, worktree mode required)"
else
	PARALLEL_MODE="false"
	set_concurrency "$HOME/.claude/skills/radin-execute/SKILL.md" "$SEQUENTIAL_RULE"
	ok "sequential execution — one sub-agent at a time"
fi

step "Sub-agent models"
# radin-execute is a skill running in the user's own thread, so its own model
# is whatever they picked with /model. Only its leaf sub-agents get a choice,
# and each role gets its own: they don't cost the same work.
MODELS="fable opus sonnet haiku"
SONNET_INDEX=3
HAIKU_INDEX=4
MODELS_RECORDED=""
if [ -n "$UPDATE" ]; then
	REC_PLANNING="$(manifest_value model_planning)"
	REC_EXECUTION="$(manifest_value model_execution)"
	REC_REVIEW="$(manifest_value model_review)"
	REC_DEBUG="$(manifest_value model_debug)"
	REC_FACTFIND="$(manifest_value model_factfind)"
	# All five or none: a half-read manifest would silently mix recorded picks
	# with defaults, which is worse than asking.
	if [ -n "$REC_PLANNING" ] && [ -n "$REC_EXECUTION" ] && [ -n "$REC_REVIEW" ] &&
		[ -n "$REC_DEBUG" ] && [ -n "$REC_FACTFIND" ]; then
		MODEL_PLANNING="$REC_PLANNING"
		MODEL_EXECUTION="$REC_EXECUTION"
		MODEL_REVIEW="$REC_REVIEW"
		MODEL_DEBUG="$REC_DEBUG"
		MODEL_FACTFIND="$REC_FACTFIND"
		MODELS_RECORDED="1"
	fi
fi
if [ -n "$MODELS_RECORDED" ]; then
	ok "keeping recorded sub-agent models: plan $MODEL_PLANNING, exec $MODEL_EXECUTION, review $MODEL_REVIEW, debug $MODEL_DEBUG, facts $MODEL_FACTFIND"
elif prompt_yn "Choose radin-execute's sub-agent models? (defaults: sonnet, haiku for fact-finding)"; then
	# One pick covers the common case; the per-role walk is 5-6 pickers deep.
	if [ "$(prompt_pick "Same model for every role? (default: yes)" 1 "yes" "no")" = "yes" ]; then
		# shellcheck disable=SC2086  # word splitting is the point -- one arg per model
		MODEL_ALL="$(prompt_pick "model for every sub-agent role" "$SONNET_INDEX" $MODELS)"
		MODEL_PLANNING="$MODEL_ALL"
		MODEL_EXECUTION="$MODEL_ALL"
		MODEL_REVIEW="$MODEL_ALL"
		MODEL_DEBUG="$MODEL_ALL"
		MODEL_FACTFIND="$MODEL_ALL"
	else
		# shellcheck disable=SC2086
		MODEL_PLANNING="$(prompt_pick "planning sub-agent (writes the plan for one task)" "$SONNET_INDEX" $MODELS)"
		# shellcheck disable=SC2086
		MODEL_EXECUTION="$(prompt_pick "execution sub-agent (implements and commits one task)" "$SONNET_INDEX" $MODELS)"
		# shellcheck disable=SC2086
		MODEL_REVIEW="$(prompt_pick "review sub-agent (reviews the session's commits)" "$SONNET_INDEX" $MODELS)"
		# shellcheck disable=SC2086
		MODEL_DEBUG="$(prompt_pick "debug sub-agent (diagnoses one failed task)" "$SONNET_INDEX" $MODELS)"
		# shellcheck disable=SC2086
		MODEL_FACTFIND="$(prompt_pick "fact-finding sub-agent (answers one checkable question)" "$HAIKU_INDEX" $MODELS)"
	fi
	ok "sub-agent models: plan $MODEL_PLANNING, exec $MODEL_EXECUTION, review $MODEL_REVIEW, debug $MODEL_DEBUG, facts $MODEL_FACTFIND"
else
	ok "keeping default sub-agent models (sonnet; haiku for fact-finding)"
fi
set_role_models "$HOME/.claude/skills/radin-execute/SKILL.md"
set_role_models "$HOME/.claude/.radin/lib/radin-execute-prompts.md"

# Preflight for the pipx/pip-based tools below. A broken Homebrew python bottle
# (pyexpat linked against Apple's system libexpat, which lacks the symbols brew's
# expat exports) makes every pip/pipx call die with an opaque dlopen traceback.
# Probe it once here and print the fix, instead of letting pip dump the stack.
python_ok() {
	if python3 -c "import pyexpat" >/dev/null 2>&1; then
		return 0
	fi
	warn "python3 can't import pyexpat -- its Homebrew build links a libexpat"
	warn "that lacks required symbols. pip/pipx installs will fail. Fix with:"
	warn "  brew reinstall --build-from-source python@3.14"
	warn "(a plain 'brew reinstall' pulls the same broken bottle -- the"
	warn "--build-from-source flag relinks against brew's expat). Then re-run."
	return 1
}

step "Companion tools"
# Prefer brew when present (macOS, Linuxbrew). Otherwise delegate to rtk's own
# installer -- it handles Linux OS/arch detection and checksum verification
# itself, so radin doesn't reimplement that here.
if [ -n "$BREW" ]; then
	RTK_INSTALL_CMD="HOMEBREW_NO_AUTO_UPDATE=1 $BREW install rtk || HOMEBREW_NO_AUTO_UPDATE=1 $BREW upgrade rtk"
else
	RTK_INSTALL_CMD="curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh | sh"
fi
install_tool "rtk" "rtk" "$RTK_INSTALL_CMD"

# codebase-memory-mcp ships one static binary and its own installer resolves
# OS/arch and verifies checksums, so radin delegates instead of reimplementing
# that (same reasoning as rtk's fallback). `--skip-config` is not optional
# here: without it, upstream writes MCP entries, a skill, three agent
# definitions and SessionStart/SubagentStart/PreToolUse hooks into ~/.claude
# across 45 client surfaces. radin owns every ~/.claude write, and
# `radin cbm-hooks` does the two it wants, merge-only.
install_tool "codebase-memory-mcp" "codebase-memory-mcp" \
	"curl -fsSL https://raw.githubusercontent.com/DeusData/codebase-memory-mcp/main/install.sh | bash -s -- --skip-config"

# headroom complements rtk (whole-session wrap vs per-command output
# compression), not a replacement -- never phrase this as preferred over rtk.
# python_ok gates it: its stack is pip-based, and a broken brew python makes
# the install die on an opaque traceback instead of a readable skip.
install_tool "headroom" "headroom" \
	"python_ok && { pipx --version >/dev/null 2>&1 && pipx install --force headroom-ai || pip3 install --user --upgrade headroom-ai; }"

# caveman ships as a Claude Code plugin (not an npm package) -- installs via
# the plugin marketplace flow, same as the interactive `/plugin` command.
install_plugin "caveman" "caveman@caveman" "JuliusBrussee/caveman"

# ponytail ships as a Claude Code plugin too -- same marketplace flow.
install_plugin "ponytail" "ponytail@ponytail" "DietrichGebert/ponytail"

# mattpocock-skills ships from Anthropic's own official marketplace, not a
# third-party repo. radin-plan invokes its /grilling and /research skills
# rather than reimplementing an interview loop or a research step.
install_plugin "mattpocock-skills" "mattpocock-skills@claude-plugins-official" "anthropics/claude-plugins-official"

# Its own installer's default target isn't on PATH in every shell, so resolve
# the just-installed binary by path too.
cbm_bin() {
	local bin
	bin="$(command -v codebase-memory-mcp || true)"
	[ -n "$bin" ] || bin="$HOME/.local/bin/codebase-memory-mcp"
	[ -x "$bin" ] || return 1
	printf '%s' "$bin"
}

CBM_AGENT_CONFIG="false"
if CBM_BIN="$(cbm_bin)"; then
	# auto_index is off upstream, which leaves a wired session querying an empty
	# graph until someone indexes by hand. Idempotent, so it also fixes an
	# install that predates this line.
	if ! "$CBM_BIN" config set auto_index true >/dev/null 2>&1; then
		warn "could not enable codebase-memory-mcp auto-index -- run: codebase-memory-mcp config set auto_index true"
	fi

	# The whole tool: binary, then upstream's own Claude Code configuration (its
	# skill, three graph agents, user-scope MCP entry, and the hooks that route
	# Grep/Glob to the graph).
	# `radin cbm-config install` wraps that write because upstream #1200 (open
	# through v0.10.8) replaces the whole SessionStart array in settings.json
	# instead of merging: it snapshots first, runs their installer, then puts
	# back every pre-existing hook and MCP entry the write dropped. Their
	# entries stay, yours come back, and `codebase-memory-mcp update` can be
	# followed by `radin cbm-config repair` for the same reason.
	if [ -x "$HOME/.claude/.radin/bin/radin-cbm-json" ]; then
		# Same contract as install_tool: the per-item trace (SNAPSHOT/STASHED/
		# RESTORED/INTACT/CBM, and upstream's own 45-client inventory on a
		# failed run) is what a failure needs and noise on success, so it all
		# stays in one log and never reaches the terminal. Its own exit code
		# only says whether the graph came out wired: a PARTIAL run exits 0,
		# so read that back out of the log rather than claiming success.
		CBM_LOG="$HOME/.claude/.radin/cbm-config.log"
		if bash "$HOME/.claude/.radin/lib/radin-cbm-config.sh" install >"$CBM_LOG" 2>&1 </dev/null; then
			CBM_AGENT_CONFIG="true"
			if grep -q '^PARTIAL ' "$CBM_LOG"; then
				warn "codebase-memory-mcp reported a failure while configuring Claude Code,"
				warn "but its hooks and MCP entry are in place. Details: ${BOLD}$CBM_LOG${RESET}"
			else
				ok "codebase-memory-mcp wired: skill, graph agents, hooks, user-scope MCP (every repo, no per-project step)."
			fi
		else
			warn "codebase-memory-mcp configuration failed -- radin itself is unaffected."
			warn "Your own hooks were restored from the snapshot. Details: ${BOLD}$CBM_LOG${RESET}"
			info "Falling back to radin's merge-only wiring:"
			bash "$HOME/.claude/.radin/lib/radin-cbm-hooks.sh" claude-md || true
			info "Then run /radin-setup-hooks in each repo for its .mcp.json entry."
		fi
	else
		# The restore step is the compiled JSON helper, and running upstream's
		# write without it is how a machine loses caveman's and ponytail's
		# SessionStart hooks. A smaller install beats a destructive write with
		# no restore behind it.
		warn "no C compiler -- skipping upstream's own Claude Code configuration:"
		warn "its write drops other tools' SessionStart hooks (#1200) and radin"
		warn "needs radin-cbm-json to put them back. Using the merge-only wiring."
		bash "$HOME/.claude/.radin/lib/radin-cbm-hooks.sh" claude-md || true
		info "Then run /radin-setup-hooks in each repo for its .mcp.json entry."
	fi
fi

step "radin CLI on PATH"
# One `radin <backlog|state|scope|cbm-hooks|cbm-config|doctor|uninstall>`
# command instead of long lib paths in every Bash call. The dispatcher always
# lands in ~/.claude/.radin/bin; this only symlinks it into ~/.local/bin.
# Never overwrites: an existing non-radin `radin` there is named and left
# alone, and skills then fall back to the full dispatcher path.
CLI_ON_PATH="false"
# Skills get whichever invocation actually works here: bare `radin` only when
# the symlink exists AND ~/.local/bin is on PATH; the full dispatcher path
# otherwise. Written into the RADIN_CLI token by set_cli below.
# shellcheck disable=SC2016  # $HOME must stay literal in the installed file
RADIN_CLI_VALUE='"$HOME/.claude/.radin/bin/radin"'
CLI_TARGET="$HOME/.claude/.radin/bin/radin"
CLI_LINK="$HOME/.local/bin/radin"
if [ -e "$CLI_LINK" ] && [ "$(readlink "$CLI_LINK" 2>/dev/null)" != "$CLI_TARGET" ]; then
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
for f in radin-execute radin-plan radin-record radin-review radin-show \
	radin-doctor radin-uninstall radin-setup-hooks radin-stats; do
	set_cli "$HOME/.claude/skills/$f/SKILL.md" "$RADIN_CLI_VALUE"
done
set_cli "$HOME/.claude/.radin/lib/radin-execute-prompts.md" "$RADIN_CLI_VALUE"
set_cli "$HOME/.claude/.radin/lib/radin-execute-recovery.md" "$RADIN_CLI_VALUE"
set_cli "$HOME/.claude/.radin/lib/radin-prioritization.md" "$RADIN_CLI_VALUE"
set_cli "$HOME/.claude/.radin/lib/radin-execute-clarify.md" "$RADIN_CLI_VALUE"
set_cli "$HOME/.claude/.radin/lib/radin-execute-session.md" "$RADIN_CLI_VALUE"
set_cli "$HOME/.claude/.radin/lib/radin-execute-reporting.md" "$RADIN_CLI_VALUE"
set_lib "$HOME/.claude/skills/radin-execute/SKILL.md"

step "Agent guidance"
# A short section in ~/.claude/CLAUDE.md telling Claude when to reach for
# radin's skills (same pattern codebase-memory-mcp uses). Kept between
# radin:begin/end markers: a re-run rewrites only that block, everything
# outside them passes through untouched -- which is what makes writing it
# unconditionally safe on a file radin doesn't own.
CLAUDE_MD_GUIDANCE="true"
# shellcheck disable=SC2016  # backticks here are markdown code spans, not command substitution
RADIN_GUIDANCE='<!-- radin:begin -->
## radin

radin keeps a per-repo backlog in `<repo-root>/.claude/.radin/` so tasks
survive past one conversation. Reach for it instead of ad-hoc task tracking:

- A bug, idea, or follow-up comes up mid-session: record it with `/radin-record`.
- The user asks what is pending: `/radin-show`. One entry needs a plan first: `/radin-plan`.
- The user wants the backlog worked through: `/radin-execute`. A code review whose findings should become tasks: `/radin-review`.
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
# `radin update` reads this to decide between `git pull` in a dev clone and a
# fresh tarball download.
printf '%s\n' "$RADIN_ROOT" >"$HOME/.claude/.radin/install_root"
INSTALLED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat >"$MANIFEST_FILE" <<EOF
{
  "version": "$MANIFEST_VERSION",
  "installed_at": "$INSTALLED_AT",
  "parallel_execution": $PARALLEL_MODE,
  "install_root": "$RADIN_ROOT",
  "model_planning": "$MODEL_PLANNING",
  "model_execution": "$MODEL_EXECUTION",
  "model_review": "$MODEL_REVIEW",
  "model_debug": "$MODEL_DEBUG",
  "model_factfind": "$MODEL_FACTFIND",
  "claude_md_guidance": $CLAUDE_MD_GUIDANCE,
  "cbm_agent_config": $CBM_AGENT_CONFIG,
  "cli_on_path": $CLI_ON_PATH,
  "skills": [
    "radin-execute",
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
    "radin-json.sh",
    "radin-backlog.sh",
    "radin-tui.c",
    "radin-cbm-json.c",
    "radin-state.sh",
    "radin-scope.sh",
    "radin-prioritization.md",
    "radin-execute-prompts.md",
    "radin-execute-recovery.md",
    "radin-execute-reporting.md",
    "radin-execute-clarify.md",
    "radin-execute-session.md",
    "radin-execute-resume.md",
    "radin-cbm-hooks.sh",
    "radin-cbm-config.sh",
    "radin-update.sh",
    "radin-doctor.sh",
    "radin-uninstall.sh"
  ],
  "companion_tools": {
    "rtk": $(json_bool_cmd rtk),
    "codebase-memory-mcp": $(cbm_bin >/dev/null 2>&1 && printf 'true' || printf 'false'),
    "headroom": $(json_bool_cmd headroom),
    "caveman": $(json_bool_plugin "caveman@caveman"),
    "ponytail": $(json_bool_plugin "ponytail@ponytail"),
    "mattpocock-skills": $(json_bool_plugin "mattpocock-skills@claude-plugins-official")
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
	info "task, then ${BOLD}/radin-execute${RESET} to work the backlog. ${BOLD}radin${RESET} opens the TUI."
fi
info "${BOLD}radin doctor${RESET} checks this install · ${BOLD}radin update${RESET} updates the whole stack."
