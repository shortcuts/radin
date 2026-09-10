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
printf "%b\n" "${RESET}${DIM}  Installs backlog-workflow skills into ~/.claude, then offers a curated"
printf "%b\n\n" "  set of optional token-saving companion tools. Nothing installs without a yes.${RESET}"

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
for f in radin-namespace.sh radin-json.sh radin-backlog.sh radin-state.sh \
	radin-scope.sh radin-prioritization.md radin-execute-prompts.md \
	radin-execute-recovery.md radin-execute-reporting.md radin-crg-hooks.sh \
	radin-doctor.sh radin-uninstall.sh; do
	cp "$RADIN_ROOT/lib/$f" "$HOME/.claude/.radin/lib/"
done
for s in radin-execute radin-review radin-record radin-show radin-plan \
	radin-setup-hooks radin-stats radin-doctor radin-uninstall; do
	cp -r "$RADIN_ROOT/skills/$s" "$HOME/.claude/skills/"
done
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

install_if_confirmed() {
	local name="$1" check_cmd="$2" install_cmd="$3" extra_confirm="${4:-}"
	if command -v "$check_cmd" >/dev/null 2>&1 && [ -z "$FORCE" ]; then
		ok "$name already installed, skipping (--force to update)."
		return
	fi
	prompt_yn "Install $name?" || return 0
	if [ -n "$extra_confirm" ]; then
		info "$extra_confirm"
		prompt_yn "Confirm: install $name's Python/pip stack?" || return 0
	fi
	# Companion installs are advisory: a failed one warns, never aborts radin's
	# own install (set -e would otherwise kill the script here).
	eval "$install_cmd" || warn "$name install failed -- radin itself is unaffected."
}

install_plugin_if_confirmed() {
	local name="$1" plugin_id="$2" marketplace_source="$3"
	if command -v claude >/dev/null 2>&1 && claude plugin list 2>/dev/null | grep -q "$plugin_id"; then
		if [ -z "$FORCE" ]; then
			ok "$name already installed, skipping (--force to update)."
			return
		fi
		{
			claude plugin marketplace update
			claude plugin update "$plugin_id"
		} || warn "$name update failed -- radin itself is unaffected."
		return
	fi
	prompt_yn "Install $name?" || return 0
	{
		claude plugin marketplace add "$marketplace_source"
		claude plugin install "$plugin_id"
	} || warn "$name install failed -- radin itself is unaffected."
}

# Every sub-agent role ships a distinct RADIN_MODEL_<ROLE> token instead of a
# model name, so no model is forced and each role is set independently below.
MODEL_PLANNING="sonnet"
MODEL_EXECUTION="sonnet"
MODEL_REVIEW="sonnet"
MODEL_REFUTE="sonnet"
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
		-e "s/RADIN_MODEL_REFUTE/${MODEL_REFUTE}/g" \
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

# The agent ships no concurrency rule of its own -- only a marker line. awk
# swaps that line for whichever rule the answer below picks, so the agent file
# never carries a variant the user didn't choose.
# shellcheck disable=SC2016  # backticks here are markdown code spans, not command substitution
SEQUENTIAL_RULE='- **One execution sub-agent at a time.** Dispatch one task, wait for its `STATUS:` line, finish its bookkeeping, then dispatch the next. Never put two `Task` calls in one message, however independent the tasks look. Batching other tool calls stays fine -- this rule is about `Task` only, and about execution sub-agents only: read-only dispatches stay parallel per Core Constraints.'
# shellcheck disable=SC2016  # backticks here are markdown code spans, not command substitution
PARALLEL_RULE='- **Concurrency allowed, and only under these conditions.** Several execution sub-agents may run in the same turn when they share no `depends_on` chain and no files, and only when Phase 0.5 recorded the worktree answer as yes -- parallel agents in one worktree corrupt each other commits. Worktree answer is no, or file overlap is at all unclear: dispatch strictly one at a time. Launch parallel ones in one message, every one still `run_in_background: false`: a background task cannot notify a sub-agent turn, so you would wait forever. Per-task steps stay unchanged, and each targets that task own tree via `radin-state.sh task-dir` -- its own `dirty-check`, its own commit, its own `task-done`. Never `dirty-check` the shared checkout while another agent is in flight: you would stash a sibling task work out from under it.'

# Per-task verification is off unless asked for: it adds one sub-agent to
# every successful task, and the skill must ship exactly one of these two
# rules rather than a marker the model interprets itself.
# shellcheck disable=SC2016  # backticks here are markdown code spans, not command substitution
REFUTE_ON_RULE='- **Verify a `SUCCESS` before you record it.** Send the **Refuter prompt** from `radin-execute-prompts.md`, substituting the commit hash(es) and the tree from `task-dir`. Never forward the execution sub-agent report: the diff is the claim under test. Route on its `VERDICT:` line, never on its prose. `ACCEPT`: continue to the bookkeeping below. `REWORK`: append its must-fixes to the task file as a `**Rework:**` line (`radin-backlog.sh append`), then re-run this task from Step 4b -- `start` bumps `attempts`, so the cap still ends it. `UNVERIFIED`: record the task as done anyway, since the work is committed and the tree is clean, and name it in the Phase 5 summary as unverified.'
# shellcheck disable=SC2016  # backticks here are markdown code spans, not command substitution
REFUTE_OFF_RULE='- **No refuter pass.** Per-task verification was declined at install time, so a `SUCCESS` goes straight to the bookkeeping below. Never dispatch a verification sub-agent of your own, and never re-read the diff yourself to make up for it -- reading it into this context is the cost the pass exists to avoid. `/radin-review` at Phase 6 is where the session verified.'

set_refute() {
	local file="$1" rule="$2" tmp
	tmp="$(mktemp)"
	awk -v rule="$rule" '/^<!-- radin:refute -->$/ { print rule; next } { print }' \
		"$file" >"$tmp" && mv "$tmp" "$file"
	# A surviving marker leaves Step 4b with no rule for a SUCCESS report, and
	# the model then decides whether to verify -- louder to fail here.
	if grep -q '^<!-- radin:refute -->$' "$file"; then
		printf "%b\n" "${RED}${RAT} failed to write the verification rule into $file.${RESET} Re-run the installer." >&2
		exit 1
	fi
}

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

step "Parallel execution (optional)"
if [ "$(prompt_pick "How should radin-execute run sub-agents? (parallel only ever applies to independent tasks)" 2 "parallel" "sequential")" = "parallel" ]; then
	PARALLEL_MODE="true"
	set_concurrency "$HOME/.claude/skills/radin-execute/SKILL.md" "$PARALLEL_RULE"
	ok "parallel execution allowed (independent tasks only, worktree mode required)"
else
	PARALLEL_MODE="false"
	set_concurrency "$HOME/.claude/skills/radin-execute/SKILL.md" "$SEQUENTIAL_RULE"
	ok "sequential execution — one sub-agent at a time"
fi

step "Per-task verification (optional)"
REFUTER_PASS="false"
if prompt_yn "Verify every task's commit with a second sub-agent? Catches a wrong 'done' claim, costs one more agent per task (default: no)"; then
	REFUTER_PASS="true"
	set_refute "$HOME/.claude/skills/radin-execute/SKILL.md" "$REFUTE_ON_RULE"
	ok "refuter pass on -- each SUCCESS is checked against the task before it is recorded"
else
	set_refute "$HOME/.claude/skills/radin-execute/SKILL.md" "$REFUTE_OFF_RULE"
	ok "no refuter pass -- review the session at the end with /radin-review"
fi

step "Sub-agent models (optional)"
# radin-execute is a skill running in the user's own thread, so its own model
# is whatever they picked with /model. Only its leaf sub-agents get a choice,
# and each role gets its own: they don't cost the same work.
MODELS="fable opus sonnet haiku"
SONNET_INDEX=3
HAIKU_INDEX=4
if prompt_yn "Choose radin-execute's sub-agent model per role? (defaults: sonnet, haiku for fact-finding)"; then
	# shellcheck disable=SC2086  # word splitting is the point -- one arg per model
	MODEL_PLANNING="$(prompt_pick "planning sub-agent (writes the plan for one task)" "$SONNET_INDEX" $MODELS)"
	# shellcheck disable=SC2086
	MODEL_EXECUTION="$(prompt_pick "execution sub-agent (implements and commits one task)" "$SONNET_INDEX" $MODELS)"
	# shellcheck disable=SC2086
	MODEL_REVIEW="$(prompt_pick "review sub-agent (reviews the session's commits)" "$SONNET_INDEX" $MODELS)"
	# Roles the install didn't enable get no question -- the token still gets
	# its default so the prompts file never ships a literal RADIN_MODEL_.
	if [ "$REFUTER_PASS" = "true" ]; then
		# shellcheck disable=SC2086
		MODEL_REFUTE="$(prompt_pick "refuter sub-agent (verifies one task's commit)" "$SONNET_INDEX" $MODELS)"
	fi
	# shellcheck disable=SC2086
	MODEL_DEBUG="$(prompt_pick "debug sub-agent (diagnoses one failed task)" "$SONNET_INDEX" $MODELS)"
	# shellcheck disable=SC2086
	MODEL_FACTFIND="$(prompt_pick "fact-finding sub-agent (answers one checkable question)" "$HAIKU_INDEX" $MODELS)"
	ok "sub-agent models: plan $MODEL_PLANNING, exec $MODEL_EXECUTION, review $MODEL_REVIEW, refute $MODEL_REFUTE, debug $MODEL_DEBUG, facts $MODEL_FACTFIND"
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

step "Companion tools (all optional)"
# Prefer brew when present (macOS, Linuxbrew). Otherwise delegate to rtk's own
# installer -- it handles Linux OS/arch detection and checksum verification
# itself, so radin doesn't reimplement that here.
if [ -n "$BREW" ]; then
	RTK_INSTALL_CMD="$BREW install rtk || $BREW upgrade rtk"
else
	RTK_INSTALL_CMD="curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh | sh"
fi
install_if_confirmed "rtk" "rtk" "$RTK_INSTALL_CMD"

# code-review-graph ships on PyPI, not npm -- pipx keeps it in its own venv.
install_if_confirmed "code-review-graph" "code-review-graph" \
	"python_ok && { command -v pipx >/dev/null 2>&1 && pipx install --force code-review-graph || pip3 install --user --upgrade code-review-graph; }"

# headroom is a heavier Python/pip stack than rtk's static binary or
# code-review-graph -- gets a second confirmation (install_if_confirmed's
# 4th arg) on top of the normal yes/no gate. It complements rtk (whole-session
# wrap vs per-command output compression), not a replacement -- never
# phrase this as preferred over rtk.
install_if_confirmed "headroom" "headroom" \
	"python_ok && { command -v pipx >/dev/null 2>&1 && pipx install --force headroom-ai || pip3 install --user --upgrade headroom-ai; }" \
	"headroom pulls in a Python/pip stack (proxy, MCP, ML, memory -- heavier than rtk's static binary)."

# caveman ships as a Claude Code plugin (not an npm package) -- installs via
# the plugin marketplace flow, same as the interactive `/plugin` command.
install_plugin_if_confirmed "caveman" "caveman@caveman" "JuliusBrussee/caveman"

# ponytail ships as a Claude Code plugin too -- same marketplace flow.
install_plugin_if_confirmed "ponytail" "ponytail@ponytail" "DietrichGebert/ponytail"

# mattpocock-skills ships from Anthropic's own official marketplace, not a
# third-party repo. radin-plan invokes its /grilling and /research skills
# rather than reimplementing an interview loop or a research step.
install_plugin_if_confirmed "mattpocock-skills" "mattpocock-skills@claude-plugins-official" "anthropics/claude-plugins-official"

if command -v code-review-graph >/dev/null 2>&1; then
	info "code-review-graph binary installed. To wire its hooks, CLAUDE.md section"
	info "and MCP server, run the radin-setup-hooks skill from inside a project."
	info "(radin never runs 'code-review-graph install': it overwrites existing"
	info "settings.json hooks. radin's own script only adds what is missing.)"
fi

step "Agent guidance (optional)"
# A short section in ~/.claude/CLAUDE.md telling Claude when to reach for
# radin's skills (same pattern code-review-graph uses). Kept between
# radin:begin/end markers: a re-run replaces only that block, the rest of the
# user's file is never touched. Default no -- it edits a file radin doesn't
# own, so it needs an explicit yes.
CLAUDE_MD_GUIDANCE="false"
# shellcheck disable=SC2016  # backticks here are markdown code spans, not command substitution
RADIN_GUIDANCE='<!-- radin:begin -->
## radin

radin keeps a per-repo backlog in `<repo-root>/.claude/.radin/` so tasks
survive past one conversation. Reach for it instead of ad-hoc task tracking:

- A bug, idea, or follow-up comes up mid-session: record it with `/radin-record`.
- The user asks what is pending: `/radin-show`. One entry needs a plan first: `/radin-plan`.
- The user wants the backlog worked through: `/radin-execute`. A code review whose findings should become tasks: `/radin-review`.
- Never hand-edit files under `.claude/.radin/` -- every backlog operation goes through `bash ~/.claude/.radin/lib/radin-backlog.sh`.
<!-- radin:end -->'
if prompt_yn "Append a short radin section to ~/.claude/CLAUDE.md, so agents know when to use the backlog? (default: no)"; then
	CLAUDE_MD_GUIDANCE="true"
	CLAUDE_MD="$HOME/.claude/CLAUDE.md"
	touch "$CLAUDE_MD"
	GUIDANCE_TMP="$(mktemp)"
	# Strip any previous radin block, then append the current one -- idempotent
	# across re-runs, and the surrounding content passes through untouched.
	awk '/^<!-- radin:begin -->$/ { skip = 1 } !skip { print } /^<!-- radin:end -->$/ { skip = 0 }' \
		"$CLAUDE_MD" >"$GUIDANCE_TMP"
	printf '\n%s\n' "$RADIN_GUIDANCE" >>"$GUIDANCE_TMP"
	mv "$GUIDANCE_TMP" "$CLAUDE_MD"
	ok "radin section written to ${BOLD}$CLAUDE_MD${RESET} (between radin:begin/end markers)"
else
	ok "no CLAUDE.md edit -- agents discover radin through its skill descriptions"
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
  "parallel_execution": $PARALLEL_MODE,
  "refuter_pass": $REFUTER_PASS,
  "claude_md_guidance": $CLAUDE_MD_GUIDANCE,
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
    "radin-state.sh",
    "radin-scope.sh",
    "radin-prioritization.md",
    "radin-execute-prompts.md",
    "radin-execute-recovery.md",
    "radin-execute-reporting.md",
    "radin-crg-hooks.sh",
    "radin-doctor.sh",
    "radin-uninstall.sh"
  ],
  "companion_tools": {
    "rtk": $(json_bool_cmd rtk),
    "code-review-graph": $(json_bool_cmd code-review-graph),
    "headroom": $(json_bool_cmd headroom),
    "caveman": $(json_bool_plugin "caveman@caveman"),
    "ponytail": $(json_bool_plugin "ponytail@ponytail"),
    "mattpocock-skills": $(json_bool_plugin "mattpocock-skills@claude-plugins-official")
  }
}
EOF
ok "manifest written to ${BOLD}$MANIFEST_FILE${RESET}"

step "Done"
ok "radin installed. ${DIM}Go be stingy with those tokens.${RESET}"
