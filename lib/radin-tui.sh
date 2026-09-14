#!/usr/bin/env bash
# Full-screen backlog browser for humans: list, view, create, edit, recategorize
# and delete tasks without an agent in the loop. Installed to
# ~/.claude/.radin/lib/radin-tui.sh by install.sh, reached as `radin tui`.
#
# Every mutation goes through radin-backlog.sh, so the index/task-file contract
# stays in one place -- this file only draws and dispatches keys.
# Raw ANSI, no tput/ncurses/fzf: the zero-dependency rule covers the TUI too.
# Must stay bash-3.2-compatible (macOS /bin/bash).
#
# Usage: radin tui
set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKLOG="$LIB_DIR/radin-backlog.sh"
CATEGORIES="feat fix chore refactor"
BODY_HINT="# describe the task: what changes, why, which files, how to verify"

if [ ! -t 0 ] || [ ! -t 1 ]; then
	printf 'radin tui: needs an interactive terminal; use "radin backlog show" when piping\n' >&2
	exit 1
fi

N=0
SEL=0
TOP=0
FILTER=""
MSG=""
ROWS=24
COLS=80
STTY_SAVE=""

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

backlog() { bash "$BACKLOG" "$@"; }

# Arrays stay parallel and are only ever appended to by load().
ids=()
cats=()
titles=()
files=()
flags=()

load() {
	ids=()
	cats=()
	titles=()
	files=()
	flags=()
	local listing want id cat title file lq
	listing="$(backlog list 2>/dev/null || true)"
	lq="$(lower "$FILTER")"
	for want in $CATEGORIES; do
		while IFS="$(printf '\t')" read -r id cat title file; do
			[ -n "$id" ] || continue
			[ "$cat" = "$want" ] || continue
			if [ -n "$lq" ]; then
				case "$(lower "$id $title")" in
				*"$lq"*) ;;
				*) continue ;;
				esac
			fi
			ids[${#ids[@]}]="$id"
			cats[${#cats[@]}]="$cat"
			titles[${#titles[@]}]="$title"
			files[${#files[@]}]="$file"
			# Planned tasks are marked once here, not re-grepped every frame.
			if grep -q '^\*\*Plan:\*\* ' "$BACKLOG_DIR/$file" 2>/dev/null; then
				flags[${#flags[@]}]="P"
			else
				flags[${#flags[@]}]=" "
			fi
		done <<-LISTING
			$listing
		LISTING
	done
	N=${#ids[@]}
	[ "$SEL" -lt "$N" ] || SEL=$((N > 0 ? N - 1 : 0))
}

term_size() {
	local size
	size="$(stty size 2>/dev/null || true)"
	ROWS="${size% *}"
	COLS="${size#* }"
	case "$ROWS" in '' | *[!0-9]*) ROWS=24 ;; esac
	case "$COLS" in '' | *[!0-9]*) COLS=80 ;; esac
	[ "$ROWS" -ge 10 ] || ROWS=10
	[ "$COLS" -ge 40 ] || COLS=40
}

raw_on() {
	STTY_SAVE="$(stty -g)"
	stty -echo -icanon
	printf '\033[?1049h\033[?25l'
}

raw_off() {
	printf '\033[?25h\033[?1049l'
	[ -z "$STTY_SAVE" ] || stty "$STTY_SAVE"
}

cleanup() {
	raw_off
	trap - EXIT
}

# Every row is padded to the full width so the selected row's reverse-video
# block spans it, and truncated so a long title can never wrap and desync the
# frame's line count.
row() {
	local text="$1" selected="${2:-}"
	text="${text:0:$COLS}"
	if [ -n "$selected" ]; then
		printf '\033[7m%-*s\033[0m\n' "$COLS" "$text"
	else
		printf '%-*s\n' "$COLS" "$text"
	fi
}

draw() {
	term_size
	local preview_h list_h i end header footer
	preview_h=$(((ROWS - 4) / 3))
	[ "$preview_h" -ge 4 ] || preview_h=4
	list_h=$((ROWS - preview_h - 4))
	[ "$list_h" -ge 1 ] || list_h=1

	[ "$SEL" -ge "$TOP" ] || TOP="$SEL"
	[ "$SEL" -lt $((TOP + list_h)) ] || TOP=$((SEL - list_h + 1))
	[ "$TOP" -ge 0 ] || TOP=0

	header="radin backlog  ${N} task(s)"
	[ -z "$FILTER" ] || header="$header  filter:\"$FILTER\""
	[ "$N" -eq 0 ] || header="$header  [$((SEL + 1))/$N]"

	{
		printf '\033[H\033[2J'
		printf '\033[1m%-*s\033[0m\n' "$COLS" "${header:0:$COLS}"
		end=$((TOP + list_h))
		[ "$end" -le "$N" ] || end="$N"
		if [ "$N" -eq 0 ]; then
			row "  (no tasks) press n to create one"
			i=1
		else
			i="$TOP"
			while [ "$i" -lt "$end" ]; do
				if [ "$i" -eq "$SEL" ]; then
					row "$(printf ' %s %-9s %s' "${flags[$i]}" "${cats[$i]}" "${titles[$i]}")" sel
				else
					row "$(printf ' %s %-9s %s' "${flags[$i]}" "${cats[$i]}" "${titles[$i]}")"
				fi
				i=$((i + 1))
			done
			i=$((end - TOP))
		fi
		while [ "$i" -lt "$list_h" ]; do
			row ""
			i=$((i + 1))
		done

		if [ "$N" -gt 0 ]; then
			row "$(printf -- '-- %s ' "${ids[$SEL]}")"
			sed -n "1,${preview_h}p" "$(task_path)" 2>/dev/null | while IFS= read -r line; do
				row "  $line"
			done
		else
			row "--"
		fi
		footer="j/k move  enter edit  v view  n new  d delete  c category  r retitle  / filter  ? keys  q quit"
		[ -z "$MSG" ] || footer="$MSG"
		printf '\033[%d;1H\033[1m%-*s\033[0m' "$ROWS" "$COLS" "${footer:0:$COLS}"
	} 2>/dev/null
}

# The index's own `file` field, never a composed tasks/<id>.md.
task_path() {
	printf '%s/%s' "$BACKLOG_DIR" "${files[$SEL]}"
}

# Read one keypress, mapping the arrow-key escape sequences onto j/k so the
# dispatcher only ever sees single letters.
readkey() {
	local k rest
	IFS= read -rsn1 k || return 1
	if [ "$k" = "$(printf '\033')" ]; then
		IFS= read -rsn2 -t 1 rest 2>/dev/null || rest=""
		case "$rest" in
		'[A') k=k ;;
		'[B') k=j ;;
		'[C') k=l ;;
		'[D') k=h ;;
		*) k=ESC ;;
		esac
	fi
	KEY="$k"
}

# Line input needs the terminal back in cooked mode, on the last row.
prompt() {
	local label="$1" answer
	printf '\033[%d;1H\033[2K\033[?25h%s' "$ROWS" "$label"
	stty echo icanon
	IFS= read -r answer || answer=""
	stty -echo -icanon
	printf '\033[?25l'
	REPLY_LINE="$answer"
}

confirm() {
	prompt "$1 [y/N] "
	case "$REPLY_LINE" in y | Y | yes) return 0 ;; *) return 1 ;; esac
}

# $EDITOR owns the whole terminal while it runs, so hand it a normal screen
# and take the alternate one back afterwards.
run_external() {
	raw_off
	"$@" || true
	raw_on
}

edit_body() {
	[ "$N" -gt 0 ] || return 0
	run_external "${EDITOR:-vi}" "$(task_path)"
	MSG="edited ${ids[$SEL]}"
}

# One keypress beats typing a category name that then has to be validated.
pick_category() {
	printf '\033[%d;1H\033[2K\033[1mcategory: [f]eat  [x] fix  [c]hore  [r]efactor  (any other key cancels)\033[0m' "$ROWS"
	readkey || return 1
	case "$KEY" in
	f) PICKED=feat ;;
	x) PICKED=fix ;;
	c) PICKED=chore ;;
	r) PICKED=refactor ;;
	*) return 1 ;;
	esac
}

new_task() {
	local cat title body_file out
	pick_category || {
		MSG="new: cancelled"
		return 0
	}
	cat="$PICKED"
	prompt "title: "
	title="$REPLY_LINE"
	[ -n "$title" ] || {
		MSG="new: empty title, cancelled"
		return 0
	}
	body_file="$(mktemp)"
	printf '%s\n' "$BODY_HINT" >"$body_file"
	run_external "${EDITOR:-vi}" "$body_file"
	# The hint line is a prompt for the human, never part of the task body a
	# sub-agent later reads.
	grep -vxF "$BODY_HINT" "$body_file" >"$body_file.body" || true
	if [ ! -s "$body_file.body" ]; then
		rm -f "$body_file" "$body_file.body"
		MSG="new: empty body, cancelled"
		return 0
	fi
	if out="$(backlog add "$cat" "$title" <"$body_file.body" 2>&1)"; then
		MSG="$out"
	else
		MSG="add failed: $out"
	fi
	rm -f "$body_file" "$body_file.body"
	load
}

delete_task() {
	[ "$N" -gt 0 ] || return 0
	local out
	if confirm "delete \"${titles[$SEL]}\"?"; then
		if out="$(backlog remove "${ids[$SEL]}" 2>&1)"; then
			MSG="$out"
		else
			MSG="remove failed: $out"
		fi
		load
	else
		MSG="delete cancelled"
	fi
}

# `c` cycles rather than prompts: four categories, one keypress each way.
cycle_category() {
	[ "$N" -gt 0 ] || return 0
	local current next first pick out
	current="${cats[$SEL]}"
	pick=""
	first=""
	for next in $CATEGORIES; do
		[ -n "$first" ] || first="$next"
		if [ -n "$pick" ] && [ "$pick" = "PENDING" ]; then
			pick="$next"
			break
		fi
		[ "$next" = "$current" ] && pick="PENDING" || true
	done
	[ "$pick" != "PENDING" ] || pick="$first"
	if out="$(backlog set-category "${ids[$SEL]}" "$pick" 2>&1)"; then
		MSG="$out"
	else
		MSG="set-category failed: $out"
	fi
	load
}

retitle_task() {
	[ "$N" -gt 0 ] || return 0
	local out
	prompt "new title (was \"${titles[$SEL]}\"): "
	[ -n "$REPLY_LINE" ] || {
		MSG="retitle cancelled"
		return 0
	}
	if out="$(backlog retitle "${ids[$SEL]}" "$REPLY_LINE" 2>&1)"; then
		MSG="$out"
	else
		MSG="retitle failed: $out"
	fi
	load
}

view_task() {
	[ "$N" -gt 0 ] || return 0
	run_external "${PAGER:-less}" "$(task_path)"
}

help_screen() {
	printf '\033[H\033[2J'
	cat <<-KEYS
		radin tui keys

		  j / down      next task
		  k / up        previous task
		  g / G         first / last task
		  enter, e      edit the task body in \$EDITOR
		  v             view the task body in \$PAGER
		  n             new task (category, title, then body in \$EDITOR)
		  d             delete the selected task (asks first)
		  c             move the task to the next category
		  r             retitle the task (its id never changes)
		  /             filter by id or title (empty clears)
		  R             reload from disk
		  q             quit

		A P in the first column marks a task radin-plan has already planned.
		Tasks live in .claude/.radin/backlog/ in this repo.

		press any key
	KEYS
	readkey || true
}

eval "$(backlog env)"
BACKLOG_DIR="${BACKLOG_INDEX%/*}"

trap 'cleanup' EXIT
raw_on
load

while :; do
	draw
	MSG=""
	readkey || break
	case "$KEY" in
	j) [ "$SEL" -lt $((N - 1)) ] && SEL=$((SEL + 1)) || true ;;
	k) [ "$SEL" -gt 0 ] && SEL=$((SEL - 1)) || true ;;
	g) SEL=0 ;;
	G) [ "$N" -eq 0 ] || SEL=$((N - 1)) ;;
	e | '') edit_body ;;
	v) view_task ;;
	n) new_task ;;
	d) delete_task ;;
	c) cycle_category ;;
	r) retitle_task ;;
	/)
		prompt "filter: "
		FILTER="$REPLY_LINE"
		SEL=0
		TOP=0
		load
		;;
	R)
		load
		MSG="reloaded"
		;;
	'?') help_screen ;;
	q) break ;;
	*) ;;
	esac
done

cleanup
