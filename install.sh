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
REFRESH=""
# RADIN_DETAILS=1 is --details for runs that cannot pass a flag.
DETAILS="${RADIN_DETAILS:-}"
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
	printf 'usage: install.sh [--yes] [--verbose] [--details] [--update] [--refresh] [--list] [--dry-run] [--force] [--wave-cap N] [--only ID[,ID...]]\n' >&2
	printf 'hosts: %s\n' "$(host_ids | tr '\n' ' ')" >&2
	exit 2
}

SELECTED=""
# Hosts an update left untouched. The manifest keeps them so the next update retries.
HELD=""
host_held() {
	case " $HELD " in *" $1 "*) return 0 ;; esac
	return 1
}
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
	# A plain install leaves a present companion alone; --refresh upgrades each one.
	--refresh) REFRESH="1" ;;
	# Prints every progress line. Without it, one line per step.
	--details) DETAILS="1" ;;
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
	--wave-cap)
		[ $# -ge 2 ] || usage_exit
		WAVE_CAP="$2"
		shift
		;;
	--wave-cap=*) WAVE_CAP="${1#--wave-cap=}" ;;
	*) usage_exit ;;
	esac
	shift
done
[ -z "$ONLY_SET" ] || select_ids "$ONLY"
[ -z "${WAVE_CAP+x}" ] || case "$WAVE_CAP" in '' | *[!0-9]* | 0*) usage_exit ;; esac

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
# Tasks one /radin-batch wave runs at once. An update keeps the stored value.
if [ -z "${WAVE_CAP+x}" ] && [ -n "$UPDATE" ]; then WAVE_CAP="$(manifest_value wave_cap)"; fi
WAVE_CAP="${WAVE_CAP:-2}"

# --verbose traces every command and lets companion installs write straight to
# the terminal. A hang shows the command it is stuck in, which a captured log
# cannot: the log is only read after the command returns.
if [ -n "$VERBOSE" ]; then
	PS4='+ install.sh:${LINENO}: '
	set -x
fi

RAT='🐀'
# Progress lines (info, ok) show with --details or --verbose. Otherwise each
# step prints one line with its elapsed time, and only warnings and the final
# summary break through: a long install must not bury the one line that
# needs the user.
LOUD="$DETAILS$VERBOSE"
TTY_OUT=""
[ ! -t 1 ] || TTY_OUT="1"
clear_line() { [ -z "$TTY_OUT" ] || printf '\r\033[K'; }
say() {
	clear_line
	printf "%b\n" "${CYAN}${RAT}${RESET} $*"
}
info() { [ -z "$LOUD" ] || say "$*"; }
ok() { [ -z "$LOUD" ] || printf "%b\n" "${GREEN}${RAT}${RESET} $*"; }
warn() {
	clear_line
	printf "%b\n" "${YELLOW}${RAT}${RESET} $*"
}
STEP_N=0
STEP_TOTAL=7
STEP_NAME=""
STEP_T0=0
INSTALL_T0="$(date +%s)"
finish_step() {
	[ -n "$STEP_NAME" ] || return 0
	if [ -z "$LOUD" ]; then
		clear_line
		printf "%b\n" "${GREEN}✓${RESET} $STEP_NAME ${DIM}($(($(date +%s) - STEP_T0))s)${RESET}"
	fi
	STEP_NAME=""
}
step() {
	finish_step
	STEP_N=$((STEP_N + 1))
	STEP_NAME="$*"
	STEP_T0="$(date +%s)"
	if [ -n "$LOUD" ]; then
		printf "\n%b\n" "${BOLD}${MAGENTA}${RAT} [$STEP_N/$STEP_TOTAL] $*${RESET}"
	elif [ -n "$TTY_OUT" ]; then
		printf "%b" "${DIM}▸ $*…${RESET}"
	fi
}

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

BACK='<back>'

_tui_abort() {
	printf '\033[?25h' >"$1"
	stty "$2" <"$1"
	printf "\n%b\n" "${RED}${RAT} aborted.${RESET}" >"$1"
	exit 130
}

_pick_tui() {
	# Arrow-key picker on a real terminal. Draws to the tty, never to stdout,
	# so the caller can still capture the chosen option. Returns 1 when the
	# device can't be put in raw mode, and the numbered fallback takes over.
	local dev="$1" msg="$2" sel="$3"
	shift 3
	local count=$# saved key rest i opt back=""
	local esc=$'\033' cr=$'\r' etx=$'\003' eot=$'\004' del=$'\177' bs=$'\010'
	saved="$(stty -g <"$dev" 2>/dev/null)" || return 1
	printf "%b\n" "${YELLOW}${RAT} $msg${RESET} ${DIM}(arrows, enter to confirm${CAN_BACK:+, left to go back})${RESET}" >"$dev"
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
			'[A') sel=$((sel > 1 ? sel - 1 : count)) ;;
			'[B' | '[C') sel=$((sel < count ? sel + 1 : 1)) ;;
			'[D')
				if [ -n "${CAN_BACK:-}" ]; then
					back=1
					break
				fi
				;;
			esac
			;;
		k) sel=$((sel > 1 ? sel - 1 : count)) ;;
		j) sel=$((sel < count ? sel + 1 : 1)) ;;
		b | "$del" | "$bs")
			if [ -n "${CAN_BACK:-}" ]; then
				back=1
				break
			fi
			;;
		[1-9])
			if [ "$key" -le "$count" ]; then
				sel="$key"
			fi
			;;
		'' | "$cr") break ;;
		# raw mode turns off ISIG, so Ctrl-C and Ctrl-D arrive as bytes -- honour
		# them here or the picker becomes unquittable.
		"$etx" | "$eot") _tui_abort "$dev" "$saved" ;;
		esac
		printf '\033[%dA' "$count" >"$dev"
	done
	printf '\033[%dA\r\033[J\033[?25h' "$((count + 1))" >"$dev"
	stty "$saved" <"$dev"
	if [ -n "$back" ]; then
		printf '%s' "$BACK"
	else
		_pick_nth "$sel" "$@"
	fi
}

# Checkbox list. Items are "id:Label"; prints the ticked ids in item order,
# or $BACK. $CHECKED holds the ids ticked on entry.
_check_tui() {
	local dev="$1" msg="$2"
	shift 2
	local count=$# saved key rest i opt id box sel=1 on=" ${CHECKED:-} " note="" back="" out=""
	local esc=$'\033' cr=$'\r' etx=$'\003' eot=$'\004' del=$'\177' bs=$'\010'
	saved="$(stty -g <"$dev" 2>/dev/null)" || return 1
	printf "%b\n" "${YELLOW}${RAT} $msg${RESET} ${DIM}(space to tick, a for all, enter to confirm${CAN_BACK:+, left to go back})${RESET}" >"$dev"
	stty raw -echo <"$dev" 2>/dev/null || return 1
	printf '\033[?25l' >"$dev"
	while :; do
		i=1
		for opt in "$@"; do
			id="${opt%%:*}"
			box="[ ]"
			case "$on" in *" $id "*) box="${GREEN}[x]${RESET}" ;; esac
			if [ "$i" = "$sel" ]; then
				printf '\r\033[K %b\r\n' "${CYAN}>${RESET} $box ${BOLD}${opt#*:}${RESET}" >"$dev"
			else
				printf '\r\033[K   %b\r\n' "$box ${opt#*:}" >"$dev"
			fi
			i=$((i + 1))
		done
		printf '\r\033[K%b\r\n' "${RED}$note${RESET}" >"$dev"
		note=""
		IFS= read -r -n1 key <"$dev" || break
		case "$key" in
		"$esc")
			IFS= read -r -n2 rest <"$dev" || break
			case "$rest" in
			'[A') sel=$((sel > 1 ? sel - 1 : count)) ;;
			'[B') sel=$((sel < count ? sel + 1 : 1)) ;;
			'[D')
				if [ -n "${CAN_BACK:-}" ]; then
					back=1
					break
				fi
				;;
			esac
			;;
		k) sel=$((sel > 1 ? sel - 1 : count)) ;;
		j) sel=$((sel < count ? sel + 1 : 1)) ;;
		' ')
			id="$(_pick_nth "$sel" "$@")"
			id="${id%%:*}"
			case "$on" in
			*" $id "*) on="${on/ $id / }" ;;
			*) on="$on$id " ;;
			esac
			;;
		a)
			out=""
			for opt in "$@"; do out="$out ${opt%%:*}"; done
			if [ "$on" = "$out " ]; then on=" "; else on="$out "; fi
			;;
		b | "$del" | "$bs")
			if [ -n "${CAN_BACK:-}" ]; then
				back=1
				break
			fi
			;;
		'' | "$cr")
			if [ -n "${on// /}" ]; then break; fi
			note="   pick at least one host"
			;;
		"$etx" | "$eot") _tui_abort "$dev" "$saved" ;;
		esac
		printf '\033[%dA' "$((count + 1))" >"$dev"
	done
	printf '\033[%dA\r\033[J\033[?25h' "$((count + 2))" >"$dev"
	stty "$saved" <"$dev"
	if [ -n "$back" ]; then
		printf '%s' "$BACK"
		return
	fi
	out=""
	for opt in "$@"; do
		id="${opt%%:*}"
		case "$on" in *" $id "*) out="$out $id" ;; esac
	done
	printf '%s' "${out# }"
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

# No `brew shellenv` eval: it prepends brew's bin to PATH and would shadow a
# version-manager python3 (mise/pyenv) with brew's -- probing the wrong
# interpreter in the pyexpat preflight below. brew itself is called via $BREW.
BREW="$(command -v brew || true)"
MISE="$(command -v mise || true)"

# --only wins; an update reuses the manifest (no manifest hosts key means a v1 install, claude only);
# anything else installs claude. The wizard's Hosts step widens that on a terminal.
select_hosts() {
	local id want=""
	[ -z "$ONLY_SET" ] || return 0
	if [ -n "$UPDATE" ]; then
		for id in $(manifest_list hosts); do
			[ -z "$(host_field "$id" 1)" ] || want="$want,$id"
		done
		want="${want#,}"
		select_ids "${want:-claude}"
		return
	fi
	select_ids claude
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
# radin-batch is a skill running in the user's own thread, so its own model
# is whatever they picked with /model. Only its leaf sub-agents get a choice.
# The Agent tool takes a family alias, never a version: Claude Code resolves
# it to that family's current model.
MODELS="fable opus sonnet haiku"
SONNET_INDEX=3
HAIKU_INDEX=4
MODELS_PICKED=""
# rtk ships in more than one package manager. Installing it with brew on a
# mise-managed machine leaves behind a manager the user never chose, so the
# one question is which manager to install through. `curl` keeps rtk's
# own upstream installer.
PKG_MGR="curl"
CHECKED=""
CAN_BACK=""

wiz_detected() {
	local id
	for id in $(host_ids); do
		if host_detected "$id"; then printf ' %s' "$id"; fi
	done
}

wiz_steps() {
	local steps=""
	if [ -z "$UPDATE" ]; then
		if [ -z "$ONLY_SET" ] && have_tty; then
			case "$(wiz_detected)" in " claude" | "") ;; *) steps="hosts" ;; esac
		fi
		if host_selected claude; then steps="$steps models"; fi
		if [ -n "$BREW$MISE" ]; then steps="$steps pkg"; fi
	fi
	printf '%s' "${steps# }"
}

wiz_label() {
	case "$1" in
	hosts) printf 'Hosts' ;;
	models) printf 'Models' ;;
	*) printf 'Package manager' ;;
	esac
}

wiz_header() {
	local pos="$1" total="$2" names="$3" i=1 n line=""
	for n in $names; do
		if [ "$i" -lt "$pos" ]; then
			line="$line${GREEN}$(wiz_label "$n")${RESET} > "
		elif [ "$i" = "$pos" ]; then
			line="$line${BOLD}${CYAN}$(wiz_label "$n")${RESET} > "
		else
			line="$line${DIM}$(wiz_label "$n")${RESET} > "
		fi
		i=$((i + 1))
	done
	printf "\n%b\n\n" "${BOLD}Step $pos/$total${RESET}  ${line% > }"
}

wiz_hosts() {
	local id
	set --
	for id in $(wiz_detected); do
		set -- "$@" "$id:$(host_field "$id" 2)"
	done
	_check_tui /dev/tty "Install radin for" "$@" || printf '%s' "$CHECKED"
}

# Prints "default", "<major> <minor>", or $BACK. Left from the first list
# returns to the question, left from the question leaves the step.
wiz_models() {
	local st=1 outer="$CAN_BACK" yn major="" minor=""
	while :; do
		case "$st" in
		1)
			CAN_BACK="$outer"
			yn="$(prompt_pick "Choose radin-batch's sub-agent models? (defaults: sonnet, haiku for fact-finding and low-complexity tasks)" 2 yes no)"
			if [ "$yn" = "$BACK" ]; then
				printf '%s' "$BACK"
				return
			fi
			if [ "$yn" = yes ]; then
				st=2
			else
				printf 'default'
				return
			fi
			;;
		2)
			CAN_BACK=1
			# shellcheck disable=SC2086  # word splitting is the point -- one arg per model
			major="$(prompt_pick "planning, execution, review and debug sub-agents" "$SONNET_INDEX" $MODELS)"
			if [ "$major" = "$BACK" ]; then st=1; else st=3; fi
			;;
		*)
			CAN_BACK=1
			# shellcheck disable=SC2086
			minor="$(prompt_pick "fact-finding and low-complexity sub-agents" "$HAIKU_INDEX" $MODELS)"
			if [ "$minor" = "$BACK" ]; then
				st=2
			else
				printf '%s %s' "$major" "$minor"
				return
			fi
			;;
		esac
	done
}

wiz_pkg() {
	set --
	if [ -n "$BREW" ]; then set -- "$@" brew; fi
	if [ -n "$MISE" ]; then set -- "$@" mise; fi
	prompt_pick "install rtk through" 1 "$@" curl
}

_rep() {
	local n="$1" out=""
	while [ "$n" -gt 0 ]; do
		out="${out}─"
		n=$((n - 1))
	done
	printf '%s' "$out"
}

_row() { printf '%-16s %s' "$1" "$2"; }

review_box() {
	local title="$1" id hosts="" rows line w=${#1}
	for id in $SELECTED; do
		hosts="$hosts, $(host_field "$id" 2)"
	done
	rows="$(_row Hosts "${hosts#, }")"
	if host_selected claude; then
		rows="$rows
$(_row Models "$MODEL_MAJOR: planning, execution, review, debug")
$(_row "" "$MODEL_MINOR: fact-finding, low-complexity")"
	else
		rows="$rows
$(_row Models "n/a, Claude Code not selected")"
	fi
	rows="$rows
$(_row Concurrency "$WAVE_CAP tasks at once")
$(_row "Package manager" "$PKG_MGR")
$(_row "Install into" "$(printf '~%s' "${RADIN_HOME#"$HOME"}")")"
	while IFS= read -r line; do
		[ "${#line}" -le "$w" ] || w=${#line}
	done <<<"$rows"
	printf "%b\n" "${CYAN}┌─${RESET} ${BOLD}$title${RESET} ${CYAN}$(_rep $((w - ${#title} - 1)))┐${RESET}"
	while IFS= read -r line; do
		printf "%b\n" "${CYAN}│${RESET} $(printf '%-*s' "$w" "$line") ${CYAN}│${RESET}"
	done <<<"$rows"
	printf "%b\n" "${CYAN}└$(_rep $((w + 2)))┘${RESET}"
}

wizard() {
	local steps total pos=1 name r interactive="" majmin WIZ_DRAWN=0
	have_tty && interactive=1
	if [ -n "$UPDATE" ]; then
		MODEL_MAJOR="$(manifest_value model_planning)"
		MODEL_MAJOR="${MODEL_MAJOR:-sonnet}"
		MODEL_MINOR="$(manifest_value model_factfind)"
		MODEL_MINOR="${MODEL_MINOR:-haiku}"
		PKG_MGR="$(manifest_value package_manager)"
		PKG_MGR="${PKG_MGR:-curl}"
	fi
	case "$(wiz_detected)" in *" claude"*) CHECKED=claude ;; esac
	while :; do
		steps="$(wiz_steps)"
		# shellcheck disable=SC2086  # word splitting is the point -- one arg per step
		total="$(set -- $steps && echo $#)"
		if [ "$pos" -gt "$total" ]; then
			# The box is a summary, not a question: the last answer starts the install.
			if [ -n "$UPDATE" ]; then review_box "Recap"; else review_box "Review"; fi
			return 0
		fi
		# shellcheck disable=SC2086
		name="$(_pick_nth "$pos" $steps)"
		CAN_BACK=""
		[ "$pos" -le 1 ] || CAN_BACK=1
		WIZ_DRAWN=0
		if [ -n "$interactive" ] && [ -z "$UPDATE" ]; then
			wiz_header "$pos" "$total" "$steps"
			WIZ_DRAWN=3
		fi
		r=""
		case "$name" in
		hosts) r="$(wiz_hosts)" ;;
		models) r="$(wiz_models)" ;;
		*) r="$(wiz_pkg)" ;;
		esac
		if [ "$r" = "$BACK" ]; then
			pos=$((pos - 1))
		else
			case "$name" in
			hosts)
				CHECKED="$r"
				select_ids "${r// /,}"
				;;
			models)
				if [ "$r" = default ]; then
					MODELS_PICKED=""
					MODEL_MAJOR="sonnet"
					MODEL_MINOR="haiku"
				else
					MODELS_PICKED=1
					majmin="$r"
					MODEL_MAJOR="${majmin% *}"
					MODEL_MINOR="${majmin#* }"
				fi
				;;
			pkg) PKG_MGR="$r" ;;
			esac
			pos=$((pos + 1))
		fi
		if [ "$WIZ_DRAWN" -gt 0 ]; then
			printf '\033[%dA\r\033[J' "$WIZ_DRAWN"
		fi
	done
}
select_hosts
wizard
info "hosts: $SELECTED"

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

sha256_many() {
	if command -v sha256sum >/dev/null 2>&1; then xargs -0 sha256sum; else xargs -0 shasum -a 256; fi
}

# macOS ships shasum only; Linux ships sha256sum.
sha256_of() {
	local out
	if command -v sha256sum >/dev/null 2>&1; then
		out="$(sha256sum "$1")" || return 1
	else
		out="$(shasum -a 256 "$1")" || return 1
	fi
	printf '%s' "${out%% *}"
}

# Two renames, not one: a cross-device `mv` copies, then deletes, and a copy
# that dies halfway must not leave a ~/.radin that passes radin_home_at.
migrate_home() {
	radin_home_at "$OLD_HOME" || return 0
	if [ -n "$DRY" ]; then
		info "would move $OLD_HOME to $RADIN_HOME"
		[ -f "$MANIFEST_FILE" ] || MANIFEST_FILE="$OLD_HOME/manifest.json"
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
# BEGIN shipped (generated from SHIPPED by tests/shipped.rs; run make gen, never edit)
SHIPPED_SKILLS="radin-batch radin-do radin-plan radin-record radin-review radin-stats radin-teardown radin-uninstall"
SHIPPED_LIB="radin-host.sh radin-namespace.sh radin-json.sh radin-migrate.sh radin-tui.c forbid-claude.txt forbid-agents.txt radin-update.sh skill-names-claude.txt skill-names-agents.txt companion-skills.txt"
SHIPPED_HOSTLIB="radin-prompt-planning.md radin-prompt-execution.md radin-prompt-debug.md radin-prompt-factfind.md radin-prompt-gate.md radin-prompt-merge.md radin-leaf-contract.md radin-comment-rule.md radin-explore-rule.md radin-open-decisions.md radin-ask-rule.md radin-complexity-rule.md radin-planning-rule.md radin-prioritization.md radin-batch-recovery.md radin-batch-reporting.md radin-batch-gate.md radin-batch-merge.md radin-batch-clarify.md radin-batch-session.md radin-batch-resume.md radin-run.md radin-review-core.md"
RENAMED_SKILLS="radin-execute radin-implement radin-run"
RETIRED_SKILLS="radin-update radin-show radin-doctor radin-setup-hooks"
RETIRED_LIB="radin-tui.sh radin-crg-hooks.sh radin-execute-recovery.md radin-execute-reporting.md radin-execute-gate.md radin-execute-review.md radin-execute-clarify.md radin-execute-session.md radin-execute-resume.md radin-batch-review.md"
# END shipped
PSTACK_RAW="https://raw.githubusercontent.com/cursor/plugins/refs/heads/main/pstack/skills"
CBM_INSTALL_CMD="curl -fsSL https://raw.githubusercontent.com/DeusData/codebase-memory-mcp/main/install.sh | bash -s -- --skip-config"
CODEX_HOME_DIR="${CODEX_HOME:-$HOME/.codex}"
CAVEMAN_CODEX_CMD="curl -fsSL https://raw.githubusercontent.com/JuliusBrussee/caveman/main/install.sh | bash -s -- --only codex --non-interactive"
PONYTAIL_CODEX_CMD="codex plugin marketplace add DietrichGebert/ponytail && codex plugin add ponytail@ponytail"
RTK_CODEX_CMD="rtk init -g --codex"
# shellcheck disable=SC2016  # eval expands $CBM_BIN once cbm_bin has set it
CBM_CODEX_CMD='"$CBM_BIN" install -y --clients=codex'
OPENCODE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
# OPENCODE_CONFIG names one file, not a dir: it takes the allow rule only.
if [ -n "${OPENCODE_CONFIG:-}" ] && [ -f "$OPENCODE_CONFIG" ]; then
	OPENCODE_CONFIG_FILE="$OPENCODE_CONFIG"
else
	OPENCODE_CONFIG_FILE="$OPENCODE_DIR/opencode.json"
fi
# kind|description, one agent file each. No ":" or "#", so the YAML value stays plain.
OPENCODE_KINDS="planning|radin leaf that plans one backlog entry
execution|radin leaf that implements one planned task and commits it
review|radin leaf that reviews a staged diff
debug|radin leaf that diagnoses a failed task
factfind|radin leaf that answers one factual question
gate|radin leaf that gates a finished session
merge|radin leaf that merges task branches"
CAVEMAN_OPENCODE_CMD="curl -fsSL https://raw.githubusercontent.com/JuliusBrussee/caveman/main/install.sh | bash -s -- --only opencode --non-interactive"
PONYTAIL_OPENCODE_CMD="opencode plugin add @dietrichgebert/ponytail"
RTK_OPENCODE_CMD="rtk init -g --opencode"
# shellcheck disable=SC2016  # eval expands $CBM_BIN once cbm_bin has set it
CBM_OPENCODE_CMD='"$CBM_BIN" install -y --clients=opencode'
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

agents_selected() {
	local id
	for id in $SELECTED; do
		[ "$(host_field "$id" 3)" != agents ] || return 0
	done
	return 1
}
agents_skill_rows() { awk '!/^#/ && NF' "$RADIN_ROOT/lib/companion-skills.txt"; }
# Codex and opencode both read ~/.agents/skills; a copy in the opencode dir resolves too.
agents_skill_present() {
	[ -f "$HOME/.agents/skills/$1/SKILL.md" ] && return 0
	host_selected opencode && [ -f "${XDG_CONFIG_HOME:-$HOME/.config}/opencode/skills/$1/SKILL.md" ]
}
# Fetch a skill radin owns, or one that no checked dir has and no foreign dir blocks.
agents_skill_wanted() {
	case " $(manifest_list agents_skills) " in *" $1 "*) return 0 ;; esac
	if agents_skill_present "$1"; then return 1; fi
	[ ! -d "$HOME/.agents/skills/$1" ]
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

# Files outside any host render. radin's own home: every run replaces them.
neutral_paths() {
	local f
	for f in $SHIPPED_LIB; do printf '%s\n' "$RADIN_HOME/lib/$f"; done
	printf '%s\n' "$RADIN_HOME/bin/radin"
}

# Files one render writes, one path per line. Read from the source tree, so a
# dry run and a real run list the same files.
render_paths() {
	local s f
	for f in $SHIPPED_HOSTLIB; do printf '%s\n' "$RADIN_HOME/hosts/$1/lib/$f"; done
	for s in $SHIPPED_SKILLS; do
		if [ -d "$RADIN_ROOT/skills/$s" ]; then
			(cd "$RADIN_ROOT/skills" && find "$s" -type f | sort) | sed "s|^|$(host_skills_dir "$1")/|"
		else
			printf '%s/%s/\n' "$(host_skills_dir "$1")" "$s"
		fi
	done
}

# One path per line for every file radin writes into a manifest `files` entry.
owned_paths() {
	local r
	neutral_paths
	for r in $RENDERS; do render_paths "$r"; done
	if host_selected opencode; then opencode_paths; fi
}

opencode_paths() {
	printf '%s\n' "$OPENCODE_KINDS" | while IFS='|' read -r k _; do
		printf '%s\n' "$OPENCODE_DIR/agents/radin-$k.md"
	done
}

TAB="$(printf '\t')"
# `key<TAB>value` lines of a flat string map in the previous manifest.
manifest_map() {
	[ -f "$MANIFEST_FILE" ] || return 0
	sed -n '/^  "'"$1"'": {/,/^  }/p' "$MANIFEST_FILE" | sed -n 's/^    "\(.*\)": "\(.*\)",\{0,1\}$/\1'"$TAB"'\2/p'
}

# A manifest from before `files` owns every path of a skill or hostlib file it names.
OWNED_MAP=""
PREV_BACKUPS=""
LEGACY_MANIFEST=""
load_ownership() {
	OWNED_MAP="$(manifest_map files)"
	PREV_BACKUPS="$(manifest_map backups)"
	if [ -f "$MANIFEST_FILE" ] && ! grep -q '^  "files": {' "$MANIFEST_FILE"; then LEGACY_MANIFEST="1"; fi
}

legacy_owned() {
	local s
	[ -n "$LEGACY_MANIFEST" ] || return 1
	case "$1" in
	.claude/skills/*)
		s="${1#.claude/skills/}"
		case " $(manifest_list skills) " in *" ${s%%/*} "*) return 0 ;; esac
		;;
	.radin/hosts/claude/lib/*)
		case " $(manifest_list hostlib) " in *" ${1##*/} "*) return 0 ;; esac
		;;
	esac
	return 1
}

# Prints the recorded digest of a path under $HOME, empty for a legacy owner.
# Returns 1 when the previous manifest does not own the path.
owned_digest() {
	# Parameter expansion, not awk: classify calls this once per installed file.
	local nl='
' m rest
	m="$nl$OWNED_MAP"
	case "$m" in
	*"$nl$1$TAB"*)
		rest="${m#*"$nl$1$TAB"}"
		printf '%s' "${rest%%"$nl"*}"
		;;
	*) legacy_owned "$1" ;;
	esac
}

# free: nothing there. current: radin's, bytes as recorded. edited: radin's,
# bytes changed since. unowned: there, and the manifest does not list it.
classify() {
	local want
	path_taken "$1" || {
		echo free
		return
	}
	want="$(owned_digest "${1#"$HOME"/}")" || {
		echo unowned
		return
	}
	if [ -z "$want" ] || { [ -f "$1" ] && [ ! -L "$1" ] && [ "$(sha256_of "$1")" = "$want" ]; }; then
		echo current
	else
		echo edited
	fi
}

# The skill directory that holds a path, nothing for a lib file.
skill_dir_of() {
	local base s
	for base in "$HOME/.claude/skills" "$HOME/.agents/skills"; do
		case "$1" in
		"$base"/*)
			s="${1#"$base"/}"
			printf '%s/%s' "$base" "${s%%/*}"
			return
			;;
		esac
	done
}

# One line per host-specific target: state, path, render, unit to back up.
# A skill directory with no owned SKILL.md is unowned as a whole.
PLAN="$(mktemp)"
KEPT_FILE="$(mktemp)"
BACKUPS_FILE="$(mktemp)"
preflight() {
	local r p st unit d
	load_ownership
	: >"$PLAN"
	for r in $RENDERS; do
		while IFS= read -r p; do
			st=free
			unit=""
			case "$p" in
			*/) ;;
			*)
				st="$(classify "$p")"
				unit="$p"
				d="$(skill_dir_of "$p")"
				if [ -n "$d" ] && [ -d "$d" ]; then
					case "$(classify "$d/SKILL.md")" in free | unowned) st=unowned unit="$d" ;; esac
				fi
				;;
			esac
			printf '%s\t%s\t%s\t%s\n' "$st" "$p" "$r" "$unit" >>"$PLAN"
		done < <(render_paths "$r")
	done
}

# Without --force, a render with an unowned target is left out, and so is every host that reads it.
drop_blocked() {
	local r id ids keep units u n
	if [ -z "$FORCE" ]; then
		for r in $RENDERS; do
			units="$(awk -F'\t' -v r="$r" '$1 == "unowned" && $3 == r { print $4 }' "$PLAN" | sort -u)"
			[ -n "$units" ] || continue
			ids=""
			keep=""
			for id in $SELECTED; do
				if [ "$(host_field "$id" 3)" = "$r" ]; then ids="$ids $id"; else keep="$keep $id"; fi
			done
			ids="${ids# }"
			if [ -n "$DRY" ]; then
				while IFS= read -r u; do printf 'conflict %s\n' "$u"; done <<<"$units"
			else
				# One line: 30 near-identical ones buried every other message.
				n="$(printf '%s\n' "$units" | wc -l | tr -d ' ')"
				u="$(printf '%s\n' "$units" | head -1)"
				warn "$u exists and radin did not install it (and $((n - 1)) more): $ids skipped; --force backs it up"
				[ -z "$LOUD" ] || printf '%s\n' "$units" | sed 's/^/    /'
			fi
			[ -z "$DRY" ] || printf 'skip host %s\n' "$ids"
			[ -z "$UPDATE" ] || HELD="$HELD $ids"
			SELECTED="${keep# }"
			awk -F'\t' -v r="$r" '$3 != r' "$PLAN" >"$PLAN.new" && mv "$PLAN.new" "$PLAN"
		done
	fi
	set_renders
	[ -n "$SELECTED" ] || end_empty
}

drop_tmp() { rm -f "$PLAN" "$PLAN.new" "$KEPT_FILE" "$BACKUPS_FILE"; }

end_empty() {
	drop_tmp
	INSTALL_DONE="1"
	printf "%b\n" "${RED}${RAT} every selected host was skipped: nothing is installed.${RESET}" >&2
	exit 1
}

dry_run_report() {
	local st p r unit mgr backed=""
	info "hosts: $SELECTED${FORCE:+ (--force)}"
	while IFS= read -r p; do printf 'write %s\n' "$p"; done < <(neutral_paths)
	while IFS="$TAB" read -r st p r unit; do
		if [ "$st" = edited ] && [ -z "$FORCE" ]; then
			printf 'keep %s\n' "$p"
			continue
		fi
		case "$st" in
		unowned | edited)
			case "$backed" in *"|$unit|"*) ;; *)
				printf 'backup %s\n' "$unit"
				backed="$backed|$unit|"
				;;
			esac
			;;
		esac
		printf 'write %s\n' "$p"
	done <"$PLAN"
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
	if host_selected codex; then
		printf 'write %s\n' "$CODEX_HOME_DIR/AGENTS.md"
		printf 'run %s\n' "$CAVEMAN_CODEX_CMD" "$PONYTAIL_CODEX_CMD" "$RTK_CODEX_CMD" "$CBM_CODEX_CMD"
	fi
	if host_selected opencode; then
		printf 'write %s\n' "$OPENCODE_DIR/AGENTS.md" "$OPENCODE_CONFIG_FILE"
		opencode_paths | while IFS= read -r p; do printf 'write %s\n' "$p"; done
		printf 'run %s\n' "$CAVEMAN_OPENCODE_CMD" "$PONYTAIL_OPENCODE_CMD" "$RTK_OPENCODE_CMD" "$CBM_OPENCODE_CMD"
	fi
	if agents_selected; then
		agents_skill_rows | while read -r n _ b f; do
			agents_skill_wanted "$n" || continue
			for x in $(printf '%s' "$f" | tr ',' ' '); do printf 'run curl -fsSL %s/%s\n' "$b" "$x"; done
		done
	fi
}
set_renders
[ -z "$DRY" ] || info "dry run: nothing below is written or run"
preflight
drop_blocked
[ -z "$DRY" ] || {
	dry_run_report
	drop_tmp
	INSTALL_DONE="1"
	exit 0
}
mkdir -p "$RADIN_HOME/lib"
for f in $SHIPPED_LIB; do
	cp "$RADIN_ROOT/lib/$f" "$RADIN_HOME/lib/"
done

# A moved home still holds the pre-split rendered .md files and retired libs.
if [ -n "$MIGRATED" ]; then
	for f in $SHIPPED_HOSTLIB $RETIRED_LIB; do
		rm -f "$RADIN_HOME/lib/$f"
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
	CC_LOG2="$(mktemp)"
	# A binary whose recorded source hash still matches is not rebuilt: -O2 on
	# the TUI costs seconds and the source rarely changes between installs.
	# The two builds share no input or output, so they compile at once.
	TUI_SUM="$(sha256_of "$RADIN_HOME/lib/radin-tui.c")"
	JSON_SUM="$(sha256_of "$RADIN_HOME/lib/radin-cbm-json.c")"
	TUI_PID=""
	JSON_PID=""
	if [ -x "$RADIN_HOME/bin/radin-tui" ] && [ "$(cat "$RADIN_HOME/bin/.radin-tui.sum" 2>/dev/null)" = "$TUI_SUM" ]; then
		ok "TUI up to date."
	else
		"$TUI_CC" -O2 -o "$RADIN_HOME/bin/radin-tui" \
			"$RADIN_HOME/lib/radin-tui.c" >"$CC_LOG" 2>&1 &
		TUI_PID=$!
	fi
	if [ -x "$RADIN_HOME/bin/radin-cbm-json" ] && [ "$(cat "$RADIN_HOME/bin/.radin-cbm-json.sum" 2>/dev/null)" = "$JSON_SUM" ]; then
		ok "radin-cbm-json up to date."
	else
		"$TUI_CC" -O2 -o "$RADIN_HOME/bin/radin-cbm-json" \
			"$RADIN_HOME/lib/radin-cbm-json.c" >"$CC_LOG2" 2>&1 &
		JSON_PID=$!
	fi
	if [ -n "$TUI_PID" ]; then
		if wait "$TUI_PID"; then
			printf '%s' "$TUI_SUM" >"$RADIN_HOME/bin/.radin-tui.sum"
			ok "TUI built."
		else
			rm -f "$RADIN_HOME/bin/.radin-tui.sum"
			tail -n 20 "$CC_LOG" >&2
			warn "the TUI failed to build -- every other subcommand still works."
		fi
	fi
	if [ -n "$JSON_PID" ]; then
		if wait "$JSON_PID"; then
			printf '%s' "$JSON_SUM" >"$RADIN_HOME/bin/.radin-cbm-json.sum"
			ok "radin-cbm-json built."
		else
			rm -f "$RADIN_HOME/bin/.radin-cbm-json.sum"
			tail -n 20 "$CC_LOG2" >&2
			warn "radin-cbm-json failed to build -- radin cbm-config is unavailable;"
			warn "the merge-only wiring is used instead."
		fi
	fi
	rm -f "$CC_LOG" "$CC_LOG2"
else
	warn "no C compiler found -- skipping the TUI. Use \`radin backlog show\`."
fi

install_tool() {
	local name="$1" install_cmd="$2"
	# codebase-memory-mcp's installer targets ~/.local/bin, which is not on
	# PATH in every shell.
	if [ -z "$REFRESH" ] && { command -v "$name" || [ -x "$HOME/.local/bin/$name" ]; } >/dev/null 2>&1; then
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
PLUGIN_LIST=""
# Fills the cache in the caller's shell: plugin_state runs in a $(...) subshell
# and its own assignment would be lost.
prime_plugins() {
	command -v claude >/dev/null 2>&1 || return 0
	[ -n "$PLUGIN_LIST" ] || PLUGIN_LIST="$(claude plugin list 2>/dev/null || true)"
}
plugin_state() {
	# One `claude plugin list` per run: each call costs ~1s and the list only
	# changes through install_plugin_files, which clears the cache.
	local list="$PLUGIN_LIST"
	[ -n "$list" ] || list="$(claude plugin list 2>/dev/null || true)"
	printf '%s\n' "$list" | awk -v id="$1" '
		/❯ / { cur = ($2 == id); scope = ""; next }
		cur && /Scope:/ { scope = $2 }
		cur && scope == "user" && /Status:/ { state = /disabled/ ? "disabled" : "enabled" }
		END { if (state) print state }
	'
}

install_plugin() {
	local name="$1" plugin_id="$2" rc
	# Plugins install through the `claude` CLI and nothing else, so on a machine
	# without it say so once per plugin instead of asking and then failing.
	if ! command -v claude >/dev/null 2>&1; then
		warn "$name skipped: the 'claude' CLI is not on PATH. Install Claude Code, then re-run install.sh."
		return 0
	fi
	rc=0
	prime_plugins
	install_plugin_files "$@" || rc=$?
	# 3 means nothing changed, so the cached list is still right.
	[ "$rc" = 3 ] || PLUGIN_LIST=""
	# A plugin's hooks run only while it is enabled, and radin's execution
	# prompt relies on ponytail's SubagentStart hook.
	[ "$(plugin_state "$plugin_id")" = disabled ] || return 0
	claude plugin enable --scope user "$plugin_id" >/dev/null 2>&1 </dev/null || true
	PLUGIN_LIST=""
	[ "$(plugin_state "$plugin_id")" = enabled ] ||
		warn "$name is installed but disabled, so its hooks do not run. Run: claude plugin enable --scope user $plugin_id"
}

install_plugin_files() {
	local name="$1" plugin_id="$2" marketplace_source="$3"
	if [ -z "$REFRESH" ] && [ -n "$(plugin_state "$plugin_id")" ]; then
		ok "$name already installed."
		return 3
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

# Effort stays unset: the Agent tool picks the model's default. No install question sets it.
EFFORT_MAJOR=""
EFFORT_MINOR=""

# Quoted JSON array body of a space-separated name list.
json_names() {
	local n sep=""
	for n in $1; do
		printf '%s"%s"' "$sep" "$n"
		sep=", "
	done
}

# Every render file carries tokens instead of literals: RADIN_MODEL_<ROLE> and
# RADIN_EFFORT_<ROLE> (claude render only), RADIN_CLI (the bare `radin` once it
# is on PATH, else the full dispatcher path, so no skill knows which the user
# picked) and RADIN_LIB (the Read tool needs an absolute path, so a literal
# `$HOME` would leave the model expanding it before every on-demand doc read).
# One sed script per render and one pass per file: four passes per file cost
# seconds across ~60 files.
# No `sed -i`: BSD sed (macOS) and GNU sed (Linux) take incompatible forms of
# it. Temp-file-plus-mv avoids the divergence entirely.
write_token_script() {
	local r="$1" script="$2"
	: >"$script"
	if [ "$r" = claude ]; then
		printf 's/RADIN_MODEL_%s/%s/g\n' PLANNING "$MODEL_MAJOR" EXECUTION "$MODEL_MAJOR" REVIEW "$MODEL_MAJOR" \
			DEBUG "$MODEL_MAJOR" FACTFIND "$MODEL_MINOR" LOW "$MODEL_MINOR" >>"$script"
		printf 's/RADIN_EFFORT_%s/%s/g\n' PLANNING "$EFFORT_MAJOR" EXECUTION "$EFFORT_MAJOR" REVIEW "$EFFORT_MAJOR" \
			DEBUG "$EFFORT_MAJOR" FACTFIND "$EFFORT_MINOR" LOW "$EFFORT_MINOR" >>"$script"
	fi
	# A shell opened by codex carries no host marker, so each agents CLI call names its host.
	if [ "$r" = claude ]; then
		printf 's|RADIN_CLI|%s|g\n' "$RADIN_CLI_VALUE" >>"$script"
	else
		printf 's|RADIN_CLI|%s --host %s|g\n' "$RADIN_CLI_VALUE" "$r" >>"$script"
	fi
	printf 's|RADIN_LIB|%s|g\n' "$RADIN_HOME/hosts/$r/lib" >>"$script"
}

# A surviving token reaches the model as a literal and every dispatch, CLI call
# or doc read fails -- louder to stop here than to debug that.
check_tokens() {
	local r="$1" stage="$2" pat what hit
	for pat in 'RADIN_MODEL_:sub-agent models' 'RADIN_EFFORT_:sub-agent efforts' 'RADIN_CLI:CLI invocation' 'RADIN_LIB:lib path'; do
		# The agents render has no model line, so a survivor there is the render error below.
		[ "$r" = claude ] || case "$pat" in RADIN_MODEL_* | RADIN_EFFORT_*) continue ;; esac
		hit="$(grep -rl "${pat%%:*}" "$stage" | head -1 || true)"
		[ -n "$hit" ] || continue
		what="${pat#*:}"
		printf "%b\n" "${RED}${RAT} failed to write the $what into $hit.${RESET} Re-run the installer." >&2
		exit 1
	done
}

RENDER_ERR=""
# One render-host.sh run for every file: a fork per file cost seconds per install.
stage_render() {
	local f s pairs=""
	mkdir -p "$2/lib"
	for f in $SHIPPED_HOSTLIB; do
		pairs="$pairs$RADIN_ROOT/lib/$f$TAB$2/lib/$f"$'\n'
	done
	for s in $SHIPPED_SKILLS; do
		cp -r "$RADIN_ROOT/skills/$s" "$2/"
		pairs="$pairs$RADIN_ROOT/skills/$s/SKILL.md$TAB$2/$s/SKILL.md"$'\n'
	done
	RENDER_ERR="$(printf '%s' "$pairs" | "$RADIN_ROOT/scripts/render-host.sh" --batch "$1" 2>&1)" && return 0
	RENDER_ERR="${RENDER_ERR:-$1: render failed}"
	return 1
}

# Only warns: the Codex and opencode companion steps run after rtk and codebase-memory-mcp are installed.
install_host_companions() {
	local cli
	cli="$(host_field "$1" 4)"
	command -v "$cli" >/dev/null 2>&1 ||
		warn "$cli CLI not found: radin's own files are installed, companion steps skipped"
}

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
# A backup beside the original would load as a second skill of the same name.
backup_path() {
	local rel="${1#"$HOME"/}" dst n=0
	dst="$RADIN_HOME/backups/$STAMP/$rel"
	while path_taken "$dst"; do
		n=$((n + 1))
		dst="$RADIN_HOME/backups/$STAMP/$rel.$n"
	done
	mkdir -p "$(dirname "$dst")"
	mv "$1" "$dst"
	printf '%s\t%s\n' "${dst#"$HOME"/}" "$rel" >>"$BACKUPS_FILE"
	info "backed up $1 to $dst"
}

# Copies the staged files of one render to their targets by the preflight verdicts.
publish_stage() {
	local r="$1" stage="$2" f rel dst st unit written=0 same=0 kept=0 pairs lastdir=""
	pairs="$(mktemp)"
	while IFS= read -r f; do
		rel="${f#"$stage"/}"
		case "$rel" in
		lib/*) dst="$RADIN_HOME/hosts/$r/lib/${rel#lib/}" ;;
		*) dst="$(host_skills_dir "$r")/$rel" ;;
		esac
		printf '%s\t%s\n' "$dst" "$f"
	done < <(find "$stage" -type f | sort) >"$pairs"
	# One awk joins every staged file to its preflight verdict: a fork per file
	# cost seconds across ~100 files. "-" stands for an empty field, which
	# `read` with a tab IFS would collapse.
	while IFS="$TAB" read -r st dst f unit; do
		[ "$st" != - ] || st=""
		[ "$unit" != - ] || unit=""
		if [ "$st" != free ] && [ "$st" != unowned ] && cmp -s "$f" "$dst"; then
			same=$((same + 1))
			continue
		fi
		if [ "$st" = edited ] && [ -z "$FORCE" ]; then
			printf '%s\t%s\n' "${dst#"$HOME"/}" "$(owned_digest "${dst#"$HOME"/}")" >>"$KEPT_FILE"
			warn "kept $dst: you edited it (--force replaces it)"
			kept=$((kept + 1))
			continue
		fi
		if [ -n "$unit" ] && { [ "$st" = unowned ] || [ "$st" = edited ]; } && path_taken "$unit"; then
			backup_path "$unit"
			lastdir=""
		fi
		if [ "${dst%/*}" != "$lastdir" ]; then
			mkdir -p "${dst%/*}"
			lastdir="${dst%/*}"
		fi
		cp "$f" "$dst"
		written=$((written + 1))
	done < <(awk -F'\t' '
		NR == FNR { if (!($2 in st)) { st[$2] = $1; un[$2] = $4 } next }
		{ s = ($1 in st) ? st[$1] : ""; u = ($1 in un) ? un[$1] : ""
		  print (s == "" ? "-" : s) "\t" $1 "\t" $2 "\t" (u == "" ? "-" : u) }
	' "$PLAN" "$pairs")
	rm -f "$pairs"
	ok "$r render installed to ${BOLD}$(host_skills_dir "$r")${RESET}: $written written, $same unchanged, $kept kept"
}

# Renders into a stage dir first, so one bad file leaves its hosts out and
# writes nothing, while the other renders go on.
install_render() {
	local r="$1" id stage f s keep=""
	RENDER_ERR=""
	stage="$(mktemp -d)"
	if stage_render "$r" "$stage"; then
		local script
		script="$(mktemp)"
		write_token_script "$r" "$script"
		# One sed over every file; the .bak copies are the stage's own scratch.
		find "$stage" -type f -name '*.md' -exec sed -i.bak -f "$script" {} +
		find "$stage" -type f -name '*.md.bak' -delete
		rm -f "$script"
		check_tokens "$r" "$stage"
		# The agents prompts print no model or effort line; a token left over is a render bug.
		if [ "$r" = agents ] && grep -rqE 'RADIN_(MODEL|EFFORT)_' "$stage"; then
			RENDER_ERR="$(grep -rlE 'RADIN_(MODEL|EFFORT)_' "$stage" | head -1): model or effort token survives"
		fi
	fi
	if [ -z "$RENDER_ERR" ]; then
		publish_stage "$r" "$stage"
		if [ "$r" = claude ]; then
			# Only a dir whose SKILL.md still names itself is radin's own to remove.
			for s in $RENAMED_SKILLS $RETIRED_SKILLS; do
				if grep -qx "name: $s" "$HOME/.claude/skills/$s/SKILL.md" 2>/dev/null; then
					rm -rf "$HOME/.claude/skills/$s"
				fi
			done
		fi
		for id in $SELECTED; do
			if [ "$(host_field "$id" 3)" = "$r" ] && [ "$r" = agents ]; then install_host_companions "$id"; fi
		done
	else
		warn "$r render failed: $RENDER_ERR"
		for id in $SELECTED; do
			if [ "$(host_field "$id" 3)" = "$r" ]; then
				warn "$id is left out of this install."
				[ -z "$UPDATE" ] || HELD="$HELD $id"
			else
				keep="$keep $id"
			fi
		done
		SELECTED="${keep# }"
		set_renders
		[ -n "$SELECTED" ] || end_empty
	fi
	rm -rf "$stage"
}

step "Sub-agent models"
if [ -n "$UPDATE" ]; then
	ok "keeping sub-agent models: $MODEL_MAJOR, $MODEL_MINOR for fact-finding and low-complexity tasks"
elif ! host_selected claude; then
	:
elif [ -n "$MODELS_PICKED" ]; then
	ok "sub-agent models: $MODEL_MAJOR, $MODEL_MINOR for fact-finding and low-complexity tasks"
else
	ok "keeping default sub-agent models (sonnet; haiku for fact-finding and low-complexity tasks)"
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
for r in $RENDERS; do install_render "$r"; done
ok "skills installed"

write_guidance() {
	local file="$1" body="$2" tmp
	mkdir -p "$(dirname "$file")"
	touch "$file"
	tmp="$(mktemp)"
	# Strip any previous radin block, then append the current one -- idempotent
	# across re-runs. The second awk drops the blank lines the strip leaves at the
	# end (interior ones are held and reprinted), so a re-run stops growing the
	# file by one newline each time.
	awk '/^<!-- radin:begin -->$/ { skip = 1 } !skip { print } /^<!-- radin:end -->$/ { skip = 0 }' \
		"$file" |
		awk 'NF { while (pending-- > 0) print ""; pending = 0; print; next } { pending++ }' \
			>"$tmp"
	[ ! -s "$tmp" ] || printf '\n' >>"$tmp"
	printf '%s\n' "$body" >>"$tmp"
	mv "$tmp" "$file"
}

install_opencode_agents() {
	local k desc p st tmp
	mkdir -p "$OPENCODE_DIR/agents"
	while IFS='|' read -r k desc; do
		p="$OPENCODE_DIR/agents/radin-$k.md"
		tmp="$(mktemp)"
		sed -e "s|RADIN_AGENT_DESC|$desc|" -e "s|RADIN_AGENT_KIND|$k|" "$RADIN_ROOT/hosts/opencode-agent.md" >"$tmp"
		st="$(classify "$p")"
		if [ "$st" = edited ] || [ "$st" = unowned ]; then
			if [ -z "$FORCE" ]; then
				printf '%s\t%s\n' "${p#"$HOME"/}" "$(owned_digest "${p#"$HOME"/}" || printf -- -)" >>"$KEPT_FILE"
				warn "kept $p: you edited it (--force replaces it)"
				rm -f "$tmp"
				continue
			fi
			backup_path "$p"
		fi
		cp "$tmp" "$p"
		rm -f "$tmp"
	done <<<"$OPENCODE_KINDS"
	ok "opencode agents written to ${BOLD}$OPENCODE_DIR/agents${RESET}"
}

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

radin keeps a per-repo backlog in `<repo-root>/.radin/` so tasks
survive past one conversation. Reach for it instead of ad-hoc task tracking:

- A bug, idea, or follow-up comes up mid-session: record it with `/radin-record`.
- The user asks what is pending: run `'"$RADIN_CLI_VALUE"' backlog show` and print its output. One entry needs a plan first: `/radin-plan`.
- The user wants the backlog worked through: `/radin-batch` (it plans the entries `/radin-record` flagged, then executes), or `/radin-do <prompt>` for one ad-hoc task. A code review whose findings should become tasks: `/radin-review`.
- The user asks to mark a task done by hand: run `'"$RADIN_CLI_VALUE"' state task-done <id> <commit-hash>` (hash from `git rev-parse --short=12 HEAD`). `backlog --help` and `state --help` list every verb.
- Never hand-edit files under `.radin/` -- every backlog operation goes through the `'"$RADIN_CLI_VALUE"' backlog` CLI.
- Never guess on a broad or ambiguous ask: invoke `/mattpocock-skills:grilling` and let the user settle it before radin writes anything.
<!-- radin:end -->'
	CLAUDE_MD="$HOME/.claude/CLAUDE.md"
	write_guidance "$CLAUDE_MD" "$RADIN_GUIDANCE"
	ok "radin section written to ${BOLD}$CLAUDE_MD${RESET} (between radin:begin/end markers)"
fi

# shellcheck disable=SC2016  # backticks here are markdown code spans, not command substitution
AGENTS_GUIDANCE_BODY='<!-- radin:begin -->
## radin

radin keeps a per-repo backlog in `<repo-root>/.radin/` so tasks
survive past one conversation. Reach for it instead of ad-hoc task tracking:

- A bug, idea, or follow-up comes up mid-session: record it with the `radin-record` skill.
- The user asks what is pending: run `'"$RADIN_CLI_VALUE"' --host agents backlog show` and print its output. One entry needs a plan first: `radin-plan` skill.
- The user wants the backlog worked through: `radin-batch` skill (it plans the entries `radin-record` flagged, then executes), or `radin-do` skill for one ad-hoc task. A code review whose findings should become tasks: `radin-review` skill.
- The user asks to mark a task done by hand: run `'"$RADIN_CLI_VALUE"' --host agents state task-done <id> <commit-hash>` (hash from `git rev-parse --short=12 HEAD`). `backlog --help` and `state --help` list every verb.
- Never hand-edit files under `.radin/`. Every backlog operation goes through the `'"$RADIN_CLI_VALUE"' --host agents backlog` CLI.
- Never guess on a broad or ambiguous ask: use the `grilling` skill and let the user settle it before radin writes anything.
<!-- radin:end -->'

CODEX_GUIDANCE="false"
if host_selected codex; then
	CODEX_GUIDANCE="true"
	write_guidance "$CODEX_HOME_DIR/AGENTS.md" "$AGENTS_GUIDANCE_BODY"
	ok "radin section written to ${BOLD}$CODEX_HOME_DIR/AGENTS.md${RESET} (between radin:begin/end markers)"
fi

OPENCODE_GUIDANCE="false"
if host_selected opencode; then
	OPENCODE_GUIDANCE="true"
	write_guidance "$OPENCODE_DIR/AGENTS.md" "$AGENTS_GUIDANCE_BODY"
	ok "radin section written to ${BOLD}$OPENCODE_DIR/AGENTS.md${RESET} (between radin:begin/end markers)"
	install_opencode_agents
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
	if [ -z "$REFRESH" ] && [ -f "$THERMO_SKILL" ]; then
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
# The pstack fetches and the rtk and codebase-memory-mcp installs touch
# disjoint paths and wait on the network, so they run at once. Each install
# logs to a file that is replayed in the old order. --verbose streams, so it
# stays serial.
PSTACK_PRE="$(mktemp -d)"
RTK_INSTALL_CMD="$(rtk_cmd "$PKG_MGR")"
if host_selected claude; then
	for n in unslop technical-writing; do
		curl -fsSL "$PSTACK_RAW/$n/SKILL.md" -o "$PSTACK_PRE/$n" </dev/null 2>/dev/null &
	done
fi
if [ -z "$VERBOSE" ]; then
	BG_RTK="$(mktemp)"
	BG_CBM="$(mktemp)"
	(install_tool "rtk" "$RTK_INSTALL_CMD") >"$BG_RTK" 2>&1 &
	(install_tool "codebase-memory-mcp" "$CBM_INSTALL_CMD") >"$BG_CBM" 2>&1 &
fi
wait
install_pstack_skill() {
	local name="$1" dir="$HOME/.claude/skills/$1" tmp mine=""
	[ "$(manifest_value "$name")" = true ] && mine=1
	if [ -d "$dir" ] && [ -z "$mine" ]; then
		warn "$name skipped: $dir exists and radin did not install it."
		rm -f "$PSTACK_PRE/$name"
		return 0
	fi
	tmp="$PSTACK_PRE/$name"
	if [ "$(head -c 3 "$tmp" 2>/dev/null)" = "---" ]; then
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

# Neither manager is asked for codebase-memory-mcp -- its own installer
# resolves OS/arch and verifies checksums, which radin doesn't reimplement.
if [ -n "$VERBOSE" ]; then
	install_tool "rtk" "$RTK_INSTALL_CMD"
else
	cat "$BG_RTK"
fi

# codebase-memory-mcp ships one static binary and its own installer resolves
# OS/arch and verifies checksums, so radin delegates instead of reimplementing
# that (same reasoning as rtk's fallback). `--skip-config` is not optional
# here: without it, upstream writes MCP entries, a skill, three agent
# definitions and SessionStart/SubagentStart/PreToolUse hooks into ~/.claude
# across 45 client surfaces. radin owns every ~/.claude write, and
# `radin hooks` does the two it wants, merge-only.
if [ -n "$VERBOSE" ]; then
	install_tool "codebase-memory-mcp" "$CBM_INSTALL_CMD"
else
	cat "$BG_CBM"
	rm -f "$BG_RTK" "$BG_CBM"
fi
rmdir "$PSTACK_PRE" 2>/dev/null || true

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

if host_selected codex && command -v codex >/dev/null 2>&1; then
	if [ -f "$CODEX_HOME_DIR/hooks.json" ]; then
		mkdir -p "$RADIN_HOME/backups"
		cp "$CODEX_HOME_DIR/hooks.json" "$RADIN_HOME/backups/hooks.json.$STAMP.bak"
		info "hooks.json copied to $RADIN_HOME/backups/hooks.json.$STAMP.bak: restore it by hand if a companion replaces your hooks."
	fi
	# The *-codex names match no binary, so --update reruns each step.
	install_tool "caveman-codex" "$CAVEMAN_CODEX_CMD"
	install_tool "ponytail-codex" "$PONYTAIL_CODEX_CMD"
	if command -v rtk >/dev/null 2>&1; then
		install_tool "rtk-codex" "$RTK_CODEX_CMD"
	else
		warn "rtk not found: skipping rtk init for Codex."
	fi
	# Unverified against codebase-memory-mcp #1200 for Codex: its installer may replace the SessionStart array in hooks.json.
	if CBM_BIN="$(cbm_bin)"; then
		install_tool "codebase-memory-mcp-codex" "$CBM_CODEX_CMD"
	else
		warn "codebase-memory-mcp not found: skipping its Codex config."
	fi
fi

# Goes in after the companions: plugin add and cbm both write opencode's global config.
OPENCODE_ALLOW=""
opencode_allow_rule() {
	local f="$OPENCODE_CONFIG_FILE" real rc=0 json sep="" g
	mkdir -p "$RADIN_HOME"
	real="$(cd "$RADIN_HOME" && pwd -P)"
	set -- "$RADIN_HOME/**"
	[ "$real" = "$RADIN_HOME" ] || set -- "$@" "$real/**"
	if [ ! -e "$f" ] && [ -e "$OPENCODE_DIR/opencode.jsonc" ]; then
		rc=1
	elif [ -x "$RADIN_HOME/bin/radin-cbm-json" ]; then
		mkdir -p "$(dirname "$f")"
		"$RADIN_HOME/bin/radin-cbm-json" ensure-ext-dir "$f" "$@" || rc=$?
	else
		rc=1
	fi
	if [ "$rc" -eq 0 ]; then
		OPENCODE_ALLOW="$f"
		return 0
	fi
	json='{"permission":{"external_directory":{'
	for g in "$@"; do
		json="$json$sep\"$g\":\"allow\""
		sep=","
	done
	warn "could not edit the opencode config safely: merge this rule into ${f}:"
	printf '%s\n' "$json}}}"
}
if host_selected opencode; then
	if [ -f "$OPENCODE_CONFIG_FILE" ]; then
		mkdir -p "$RADIN_HOME/backups"
		cp "$OPENCODE_CONFIG_FILE" "$RADIN_HOME/backups/opencode.json.$STAMP.bak"
		info "opencode config copied to $RADIN_HOME/backups/opencode.json.$STAMP.bak: restore it by hand if a companion replaces your settings."
	fi
	if command -v opencode >/dev/null 2>&1; then
		# The *-opencode names match no binary, so --update reruns each step.
		install_tool "caveman-opencode" "$CAVEMAN_OPENCODE_CMD"
		install_tool "ponytail-opencode" "$PONYTAIL_OPENCODE_CMD"
		if command -v rtk >/dev/null 2>&1; then
			install_tool "rtk-opencode" "$RTK_OPENCODE_CMD"
		else
			warn "rtk not found: skipping rtk init for opencode."
		fi
		if CBM_BIN="$(cbm_bin)"; then
			install_tool "codebase-memory-mcp-opencode" "$CBM_OPENCODE_CMD"
		else
			warn "codebase-memory-mcp not found: skipping its opencode config."
		fi
	fi
	opencode_allow_rule
fi

# Codex and opencode have no plugin: fetch each skill radin invokes, unpinned like
# unslop, into ~/.agents/skills. All files of a row land together or not at all,
# so a SKILL.md never links a missing sibling. Advisory.
AGENTS_SKILLS_OWNED=""
resolve_agents_skill() {
	local name="$1" base="$2" files="$3" dir="$HOME/.agents/skills/$1" tmp f mine="" good=1
	case " $(manifest_list agents_skills) " in *" $name "*) mine=1 ;; esac
	if ! agents_skill_wanted "$name"; then
		if [ -d "$dir" ] && ! agents_skill_present "$name"; then
			warn "$name skipped: $dir exists and radin did not install it."
		fi
		[ -z "$mine" ] || AGENTS_SKILLS_OWNED="$AGENTS_SKILLS_OWNED $name "
		return 0
	fi
	tmp="$(mktemp -d)"
	for f in $(printf '%s' "$files" | tr ',' ' '); do
		mkdir -p "$tmp/$(dirname "$f")"
		curl -fsSL "$base/$f" -o "$tmp/$f" </dev/null 2>/dev/null || good=""
		[ -s "$tmp/$f" ] || good=""
	done
	[ "$(head -c 3 "$tmp/SKILL.md" 2>/dev/null)" = "---" ] || good=""
	if [ -n "$good" ]; then
		# Strip as for unslop; opencode needs name to equal the directory name.
		grep -v '^disable-model-invocation:' "$tmp/SKILL.md" |
			awk -v n="$name" '!d && /^name:/ { print "name: " n; d = 1; next } { print }' >"$tmp/SKILL.md.new"
		mv "$tmp/SKILL.md.new" "$tmp/SKILL.md"
		mkdir -p "$dir"
		cp -R "$tmp/." "$dir/"
		ok "$name installed to ${BOLD}$dir${RESET}."
		AGENTS_SKILLS_OWNED="$AGENTS_SKILLS_OWNED $name "
	else
		warn "$name download failed -- radin itself is unaffected."
		[ -z "$mine" ] || [ ! -f "$dir/SKILL.md" ] || AGENTS_SKILLS_OWNED="$AGENTS_SKILLS_OWNED $name "
	fi
	rm -rf "$tmp"
	return 0
}
if agents_selected; then
	while read -r n _ b f; do
		resolve_agents_skill "$n" "$b" "$f"
	done < <(agents_skill_rows)
else
	AGENTS_SKILLS_OWNED=" $(manifest_list agents_skills) "
fi
if host_selected codex && command -v codex >/dev/null 2>&1; then
	info "Codex: open /hooks and trust the new hooks once (caveman, ponytail, rtk, codebase-memory-mcp). radin cannot do this for you."
fi

# PRESENT/WROTE lines are progress, so they follow --details.
cbm_claude_md() {
	if [ -n "$LOUD" ]; then
		bash "$RADIN_HOME/lib/radin-cbm-hooks.sh" claude-md || true
	else
		bash "$RADIN_HOME/lib/radin-cbm-hooks.sh" claude-md >/dev/null || true
	fi
}

CBM_AGENT_CONFIG="false"
if host_selected claude && CBM_BIN="$(cbm_bin)"; then
	# The whole tool: binary, then upstream's own Claude Code configuration (its
	# skill, three graph agents, user-scope MCP entry, and the hooks that route
	# Grep/Glob to the graph).
	# This step wraps that write because upstream #1200 (open through v0.11.0)
	# replaces the whole SessionStart array in settings.json instead of
	# merging: it snapshots first, runs their installer, then puts back every
	# pre-existing hook and MCP entry the write dropped. Their entries stay,
	# yours come back, and `codebase-memory-mcp update` can be followed by
	# `radin repair` for the same reason -- the caller names no companion.
	CBM_VER="$("$CBM_BIN" --version 2>/dev/null | head -1 || true)"
	CBM_STAMP="$RADIN_HOME/cbm-wired.stamp"
	if [ -x "$RADIN_HOME/bin/radin-cbm-json" ] && [ -z "$REFRESH" ] && [ -n "$CBM_VER" ] &&
		[ "$(cat "$CBM_STAMP" 2>/dev/null)" = "$CBM_VER" ] &&
		"$RADIN_HOME/bin/radin-cbm-json" wired "$HOME/.claude/settings.json" "$HOME/.claude.json" codebase-memory-mcp >/dev/null 2>&1; then
		# Upstream's write takes ~20s and snapshots settings.json each run. The
		# same binary version with its hooks and MCP entry still in place has
		# nothing to write; --refresh forces it.
		CBM_AGENT_CONFIG="true"
		ok "codebase-memory-mcp wiring already current ($CBM_VER)."
		cbm_claude_md
	elif [ -x "$RADIN_HOME/bin/radin-cbm-json" ]; then
		# auto_index is off upstream, which leaves a wired session querying an
		# empty graph until someone indexes by hand. Idempotent. It sits in the
		# stamp miss because the call alone costs ~1.5s.
		if ! "$CBM_BIN" config set auto_index true >/dev/null 2>&1; then
			warn "could not enable codebase-memory-mcp auto-index -- run: codebase-memory-mcp config set auto_index true"
		fi
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
				[ -z "$CBM_VER" ] || printf '%s' "$CBM_VER" >"$CBM_STAMP"
			fi
			# Upstream writes no CLAUDE.md text, and a skill description alone
			# did not get agents to call the graph (25 calls in 402 sessions).
			cbm_claude_md
		else
			warn "codebase-memory-mcp configuration failed -- radin itself is unaffected."
			warn "Your own hooks were restored from the snapshot. Details: ${BOLD}$CBM_LOG${RESET}"
			info "Falling back to radin's merge-only wiring:"
			cbm_claude_md
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
		cbm_claude_md
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

step "Writing install manifest"
prime_plugins
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

# Paths of a held host, so its old digests survive in the manifest.
held_paths() {
	local id r seen=""
	for id in $HELD; do
		r="$(host_field "$id" 3)"
		case " $seen " in *" $r "*) ;; *)
			seen="$seen $r"
			render_paths "$r"
			;;
		esac
		[ "$id" != opencode ] || opencode_paths
	done
}
# One entry per line, keyed by the path under $HOME. Taken last, so each digest
# matches the final bytes; a kept file keeps the digest it had.
json_files() {
	local list sums p rel d sep=""
	list="$(mktemp)"
	sums="$(mktemp)"
	owned_paths >"$list"
	# One hash process for every file: a fork per file cost seconds.
	tr '\n' '\0' <"$list" | sha256_many | awk '{ h = $1; sub(/^[^ ]+ +\*?/, ""); print $0 "\t" h }' >"$sums"
	awk -F'\t' -v home="$HOME/" '
		FILENAME == ARGV[1] { k[$1] = $2; next }
		FILENAME == ARGV[2] { h[$1] = $2; next }
		{
			rel = $0
			if (index(rel, home) == 1) rel = substr(rel, length(home) + 1)
			d = (rel in k) ? k[rel] : h[$0]
			if (d == "") next
			printf "%s\n    \"%s\": \"%s\"", sep, rel, d
			sep = ","
		}' "$KEPT_FILE" "$sums" "$list"
	rm -f "$list" "$sums"
	sep=","
	while IFS= read -r p; do
		rel="${p#"$HOME"/}"
		d="$(awk -F'\t' -v p="$rel" '$1 == p { print $2; exit }' <<<"$OWNED_MAP")"
		[ -z "$d" ] || printf '%s\n    "%s": "%s"' "$sep" "$rel" "$d"
		[ -z "$d" ] || sep=","
	done < <(held_paths)
}
json_backups() {
	{
		printf '%s\n' "$PREV_BACKUPS"
		cat "$BACKUPS_FILE"
	} |
		awk -F'\t' 'NF == 2 { printf "%s\n    \"%s\": \"%s\"", sep, $1, $2; sep = "," }'
}
MANIFEST_HOSTS=""
for id in $(host_ids); do
	if host_selected "$id" || host_held "$id"; then MANIFEST_HOSTS="$MANIFEST_HOSTS $id"; fi
done
MANIFEST_HOSTS="${MANIFEST_HOSTS# }"
host_held claude && CLAUDE_MD_GUIDANCE="$(manifest_value claude_md_guidance)"
host_held claude && CBM_AGENT_CONFIG="$(manifest_value cbm_agent_config)"
host_held codex && CODEX_GUIDANCE="$(manifest_value codex_guidance)"
host_held opencode && OPENCODE_GUIDANCE="$(manifest_value opencode_guidance)"
host_held opencode && OPENCODE_ALLOW="$(manifest_value opencode_allow)"
CLAUDE_MD_GUIDANCE="${CLAUDE_MD_GUIDANCE:-false}"
CBM_AGENT_CONFIG="${CBM_AGENT_CONFIG:-false}"
CODEX_GUIDANCE="${CODEX_GUIDANCE:-false}"
OPENCODE_GUIDANCE="${OPENCODE_GUIDANCE:-false}"
AGENTS_CLIS=""
for id in $MANIFEST_HOSTS; do
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
  "wave_cap": $WAVE_CAP,
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
  "codex_guidance": $CODEX_GUIDANCE,
  "opencode_guidance": $OPENCODE_GUIDANCE,
  "opencode_allow": "$OPENCODE_ALLOW",
  "cbm_agent_config": $CBM_AGENT_CONFIG,
  "cli_on_path": $CLI_ON_PATH,
  "hosts": [$(json_names "$MANIFEST_HOSTS")],
  "agents_clis": [$(json_names "$AGENTS_CLIS")],
  "skills": [$(json_names "$SHIPPED_SKILLS thermo-nuclear")],
  "lib": [$(json_names "$SHIPPED_LIB")],
  "hostlib": [$(json_names "$SHIPPED_HOSTLIB")],
  "agents_skills": [$(json_names "$AGENTS_SKILLS_OWNED")],
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
  },
  "backups": {$(json_backups)
  }
}
EOF
drop_tmp
ok "manifest written to ${BOLD}$MANIFEST_FILE${RESET}"

finish_step
INSTALL_DONE="1"
ELAPSED=$(($(date +%s) - INSTALL_T0))
if [ -n "$UPDATE" ]; then
	say "radin updated in ${ELAPSED}s. ${DIM}Go be stingy with those tokens.${RESET}"
else
	say "radin installed in ${ELAPSED}s. ${DIM}Go be stingy with those tokens.${RESET}"
	say "Open Claude Code in a repo and run ${BOLD}/radin-record${RESET} to file your first"
	say "task, then ${BOLD}/radin-batch${RESET} to work the backlog. ${BOLD}radin${RESET} opens the TUI."
fi
[ -z "$MIGRATED" ] || warn "restart open Claude sessions: they hold the old path"
say "${BOLD}radin doctor${RESET} checks this install · ${BOLD}radin update${RESET} updates radin itself."
