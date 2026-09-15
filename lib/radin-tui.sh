#!/usr/bin/env bash
# Full-screen backlog browser for humans: list, view, create, edit, recategorize
# and delete tasks without an agent in the loop. Installed to
# ~/.claude/.radin/lib/radin-tui.sh by install.sh, reached as `radin tui`.
#
# Every mutation and every read goes through radin-backlog.sh / radin-state.sh,
# so the index/task-file contract stays in one place -- this file only draws
# and dispatches keys.
# Raw ANSI, no tput/ncurses/fzf: the zero-dependency rule covers the TUI too.
# Must stay bash-3.2-compatible (macOS /bin/bash).
#
# Usage: radin tui
set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKLOG="$LIB_DIR/radin-backlog.sh"
STATE="$LIB_DIR/radin-state.sh"
TAB="$(printf '\t')"
# Tab is IFS whitespace, so `IFS=$TAB read` collapses the empty field an unset
# priority leaves behind and shifts depends_on into it. Split on US instead.
US="$(printf '\037')"
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
MODE=list
# bash 3.2 has no associative arrays, so the collapsed-epic set is a
# space-delimited string, matched the way radin-backlog.sh matches its own.
COLLAPSED=""
TASK_N=0
DETAIL_FILE=""
DETAIL_FOR=""
DONE_N=0
DONE_SEL=0
DONE_TOP=0
PRIO_MIN=""
PRIO_MAX=""
# NO_COLOR is the only opt-out: a non-tty already exits above.
COLOR=1
[ -z "${NO_COLOR:-}" ] || COLOR=""

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

backlog() { bash "$BACKLOG" "$@"; }

# Arrays stay parallel and are only ever appended to by load(). They are
# per-task; row_task/row_epic below are the per-visible-row view of them.
ids=()
cats=()
titles=()
files=()
flags=()
prios=()
deps=()
epics=()
row_task=()
row_epic=()
done_rows=()
pick_vals=()
pick_labels=()
pick_marked=""
PICK_RESULT=""

load() {
	ids=()
	cats=()
	titles=()
	files=()
	flags=()
	prios=()
	deps=()
	epics=()
	PRIO_MIN=""
	PRIO_MAX=""
	local listing want id cat title file prio dep lq planned epic rest
	listing="$(backlog list 2>/dev/null | tr "$TAB" "$US" || true)"
	# One call for the whole backlog: `meta` per task is quadratic.
	planned="$(backlog planned 2>/dev/null || true)"
	lq="$(lower "$FILTER")"
	for want in $CATEGORIES; do
		while IFS="$US" read -r id cat title file prio dep; do
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
			prios[${#prios[@]}]="$prio"
			case "$prio" in '' | *[!0-9]*) ;; *)
				[ -n "$PRIO_MIN" ] && [ "$prio" -ge "$PRIO_MIN" ] || PRIO_MIN="$prio"
				[ -n "$PRIO_MAX" ] && [ "$prio" -le "$PRIO_MAX" ] || PRIO_MAX="$prio"
				;;
			esac
			deps[${#deps[@]}]="$dep"
			epic=""
			case "$file" in
			tasks/*/*)
				rest="${file#tasks/}"
				epic="${rest%%/*}"
				;;
			esac
			epics[${#epics[@]}]="$epic"
			# Newline-delimited, so dark-mode never matches dark-mode-2.
			case "
$planned
" in
			*"
$id
"*) flags[${#flags[@]}]="P" ;;
			*) flags[${#flags[@]}]=" " ;;
			esac
		done <<-LISTING
			$listing
		LISTING
	done
	TASK_N=${#ids[@]}
	DETAIL_FOR=""
	build_rows
}

# The visible rows: ungrouped tasks first, then one collapsible header per
# epic followed by its children. A collapsed epic's children are absent from
# the row arrays, which is why j/k/g/G need no collapse logic of their own.
build_rows() {
	row_task=()
	row_epic=()
	local i e epic_list
	i=0
	while [ "$i" -lt "$TASK_N" ]; do
		if [ -z "${epics[$i]}" ]; then
			row_task[${#row_task[@]}]="$i"
			row_epic[${#row_epic[@]}]=""
		fi
		i=$((i + 1))
	done
	epic_list="$(
		i=0
		while [ "$i" -lt "$TASK_N" ]; do
			[ -z "${epics[$i]}" ] || printf '%s\n' "${epics[$i]}"
			i=$((i + 1))
		done | sort -u
	)"
	# shellcheck disable=SC2086
	for e in $epic_list; do
		row_task[${#row_task[@]}]=-1
		row_epic[${#row_epic[@]}]="$e"
		case " $COLLAPSED " in *" $e "*) continue ;; esac
		i=0
		while [ "$i" -lt "$TASK_N" ]; do
			if [ "${epics[$i]}" = "$e" ]; then
				row_task[${#row_task[@]}]="$i"
				row_epic[${#row_epic[@]}]=""
			fi
			i=$((i + 1))
		done
	done
	N=${#row_task[@]}
	[ "$SEL" -lt "$N" ] || SEL=$((N > 0 ? N - 1 : 0))
}

# The selected row's task index, or nothing when an epic header is selected.
cur_task() {
	[ "$N" -gt 0 ] || return 0
	[ "${row_task[$SEL]}" -ge 0 ] || return 0
	printf '%s' "${row_task[$SEL]}"
}

toggle_collapse() {
	[ "$N" -gt 0 ] || return 0
	local e="${row_epic[$SEL]}" kept="" x
	[ -n "$e" ] || return 0
	case " $COLLAPSED " in
	*" $e "*)
		for x in $COLLAPSED; do [ "$x" = "$e" ] || kept="$kept $x"; done
		COLLAPSED="$kept"
		;;
	*) COLLAPSED="$COLLAPSED $e" ;;
	esac
	DETAIL_FOR=""
	build_rows
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
	[ -z "$DETAIL_FILE" ] || rm -f "$DETAIL_FILE"
	trap - EXIT
}

# Every row is padded to the full width so the selected row's reverse-video
# block spans it, and truncated so a long title can never wrap and desync the
# frame's line count.
row() {
	local text="$1" selected="${2:-}" pre="${3:-}" post=""
	text="${text:0:$COLS}"
	[ -z "$pre" ] || post='\033[0m'
	if [ -n "$selected" ]; then
		pre="$pre\033[7m"
		post='\033[0m'
	fi
	printf "$pre%-*s$post\n" "$COLS" "$text"
}

# Bands are relative to the set priorities now loaded, so this row's colour
# moves when an unrelated task's number does -- chosen over a fixed palette
# because priority is an unbounded integer. $1 is a task index.
prio_colour() {
	local p="${prios[$1]}" span off
	[ -n "$COLOR" ] && [ -n "$PRIO_MIN" ] || return 0
	case "$p" in '' | *[!0-9]*) return 0 ;; esac
	span=$((PRIO_MAX - PRIO_MIN))
	[ "$span" -gt 0 ] || {
		printf '\033[33m'
		return 0
	}
	off=$(((p - PRIO_MIN) * 3))
	if [ "$off" -ge $((span * 2)) ]; then
		printf '\033[31m'
	elif [ "$off" -ge "$span" ]; then
		printf '\033[33m'
	else
		printf '\033[32m'
	fi
}

draw() {
	term_size
	local preview_h list_h i end header footer ti marker text colour
	preview_h=$(((ROWS - 4) / 3))
	[ "$preview_h" -ge 4 ] || preview_h=4
	list_h=$((ROWS - preview_h - 4))
	[ "$list_h" -ge 1 ] || list_h=1

	[ "$SEL" -ge "$TOP" ] || TOP="$SEL"
	[ "$SEL" -lt $((TOP + list_h)) ] || TOP=$((SEL - list_h + 1))
	[ "$TOP" -ge 0 ] || TOP=0

	header="radin backlog  ${TASK_N} task(s)"
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
				ti="${row_task[$i]}"
				if [ "$ti" -lt 0 ]; then
					case " $COLLAPSED " in
					*" ${row_epic[$i]} "*) marker="+" ;;
					*) marker="-" ;;
					esac
					text="$(printf ' %s epic: %s' "$marker" "${row_epic[$i]}")"
				elif [ -n "${epics[$ti]}" ]; then
					text="$(printf '   %s %-9s %s' "${flags[$ti]}" "${cats[$ti]}" "${titles[$ti]}")"
				else
					text="$(printf ' %s %-9s %s' "${flags[$ti]}" "${cats[$ti]}" "${titles[$ti]}")"
				fi
				if [ "$ti" -lt 0 ]; then colour=""; else colour="$(prio_colour "$ti")"; fi
				if [ "$i" -eq "$SEL" ]; then
					row "$text" sel "$colour"
				else
					row "$text" "" "$colour"
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
			ensure_detail
			row "$(printf -- '-- %s ' "$(pane_label)")"
			sed -n "1,${preview_h}p" "$DETAIL_FILE" 2>/dev/null | while IFS= read -r line; do
				row "  $line"
			done
		else
			row "--"
		fi
		footer="j/k move  enter edit/collapse  v detail  n new  d delete  c category  r retitle  / filter  Tab done  ? keys  q quit"
		[ -z "$MSG" ] || footer="$MSG"
		printf '\033[%d;1H\033[1m%-*s\033[0m' "$ROWS" "$COLS" "${footer:0:$COLS}"
	} 2>/dev/null
}

# The index's own `file` field, never a composed tasks/<id>.md. $1 is a task
# index, not a row index.
task_path() {
	printf '%s/%s' "$BACKLOG_DIR" "${files[$1]}"
}

pane_label() {
	local ti
	ti="$(cur_task)"
	if [ -n "$ti" ]; then
		printf '%s' "${ids[$ti]}"
	else
		printf 'epic: %s' "${row_epic[$SEL]}"
	fi
}

# The whole human-side composition: everything the agent-facing stack keeps
# behind pointers, gathered for the selected row.
compose_detail() {
	local ti plans p abs d t i
	: >"$DETAIL_FILE"
	{
		ti="$(cur_task)"
		if [ -z "$ti" ]; then
			printf '# epic: %s\n\n' "${row_epic[$SEL]}"
			backlog epic-show "${row_epic[$SEL]}" 2>/dev/null || printf '(no description)\n'
			printf '\n## Tasks\n\n'
			i=0
			while [ "$i" -lt "$TASK_N" ]; do
				[ "${epics[$i]}" != "${row_epic[$SEL]}" ] || printf -- '- %s\n' "${titles[$i]}"
				i=$((i + 1))
			done
		else
			printf '# %s\n\n' "${titles[$ti]}"
			printf 'id: %s\ncategory: %s\npriority: %s\n' \
				"${ids[$ti]}" "${cats[$ti]}" "${prios[$ti]:-(unset)}"
			printf '\n## Task\n\n'
			cat "$(task_path "$ti")" 2>/dev/null
			printf '\n## Epic\n\n'
			if [ -n "${epics[$ti]}" ]; then
				printf '%s\n\n' "${epics[$ti]}"
				backlog epic-show "${epics[$ti]}" 2>/dev/null || printf '(no description)\n'
			else
				printf '(ungrouped)\n'
			fi
			printf '\n## Plans\n\n'
			plans="$(backlog meta "${ids[$ti]}" 2>/dev/null | sed -n "s/^plan$TAB//p")"
			if [ -z "$plans" ]; then
				printf '(no plan)\n'
			else
				while IFS= read -r p; do
					[ -n "$p" ] || continue
					case "$p" in /*) abs="$p" ;; *) abs="$NAMESPACE_DIR/$p" ;; esac
					printf '### %s\n\n' "$p"
					if [ -f "$abs" ]; then cat "$abs"; else printf '(plan file missing)\n'; fi
					printf '\n'
				done <<-PLANS
					$plans
				PLANS
			fi
			printf '\n## Depends on\n\n'
			if [ -z "${deps[$ti]}" ]; then
				printf '(none)\n'
			else
				# shellcheck disable=SC2046,SC2086
				for d in $(printf '%s' "${deps[$ti]}" | tr ',' ' '); do
					t="$(backlog find "$d" 2>/dev/null | head -n1 | cut -f3)"
					printf -- '- %s -- %s\n' "$d" "${t:-(unknown id)}"
				done
			fi
		fi
	} >>"$DETAIL_FILE" 2>/dev/null
}

# Redraws are free; only a selection change pays for the CLI calls.
ensure_detail() {
	if [ "$DETAIL_FOR" = "$SEL" ] && [ -s "$DETAIL_FILE" ]; then
		return 0
	fi
	compose_detail
	DETAIL_FOR="$SEL"
}

load_done() {
	done_rows=()
	local out id hash
	out="$(bash "$STATE" completed-list "$NAMESPACE_DIR/state/completed.json" 2>/dev/null || true)"
	while IFS="$TAB" read -r id hash; do
		[ -n "$id" ] || continue
		done_rows[${#done_rows[@]}]="$(printf ' %-52s %s' "$id" "$hash")"
	done <<-DONE
		$out
	DONE
	DONE_N=${#done_rows[@]}
	[ "$DONE_SEL" -lt "$DONE_N" ] || DONE_SEL=$((DONE_N > 0 ? DONE_N - 1 : 0))
}

draw_done() {
	term_size
	local list_h i end header footer
	list_h=$((ROWS - 2))
	[ "$list_h" -ge 1 ] || list_h=1
	[ "$DONE_SEL" -ge "$DONE_TOP" ] || DONE_TOP="$DONE_SEL"
	[ "$DONE_SEL" -lt $((DONE_TOP + list_h)) ] || DONE_TOP=$((DONE_SEL - list_h + 1))
	[ "$DONE_TOP" -ge 0 ] || DONE_TOP=0
	header="radin done  ${DONE_N} completed"
	{
		printf '\033[H\033[2J'
		printf '\033[1m%-*s\033[0m\n' "$COLS" "${header:0:$COLS}"
		end=$((DONE_TOP + list_h))
		[ "$end" -le "$DONE_N" ] || end="$DONE_N"
		if [ "$DONE_N" -eq 0 ]; then
			row "  (nothing completed yet)"
			i=1
		else
			i="$DONE_TOP"
			while [ "$i" -lt "$end" ]; do
				if [ "$i" -eq "$DONE_SEL" ]; then
					row "${done_rows[$i]}" sel
				else
					row "${done_rows[$i]}"
				fi
				i=$((i + 1))
			done
			i=$((end - DONE_TOP))
		fi
		while [ "$i" -lt "$list_h" ]; do
			row ""
			i=$((i + 1))
		done
		footer="j/k move  Tab back  R reload  q quit  (read-only)"
		[ -z "$MSG" ] || footer="$MSG"
		printf '\033[%d;1H\033[1m%-*s\033[0m' "$ROWS" "$COLS" "${footer:0:$COLS}"
	} 2>/dev/null
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

# One chooser for every key that needs one: $1 is multi (a set, space toggles)
# or single (one value). $2 title, $3 newline-delimited "value<TAB>label"
# candidates, $4 space-delimited values to pre-mark (multi only).
# Candidates arrive as an argument, never on stdin -- readkey owns fd 0.
# Sets PICK_RESULT to the space-delimited answer ("" is legal in multi mode:
# it means clear). Returns 1 when the user cancels or there is nothing to pick.
pick() {
	local kind="$1" title="$2" items="$3" v l n sel=0 ptop=0 list_h i end mark kept x footer
	pick_vals=()
	pick_labels=()
	pick_marked="${4:-}"
	while IFS="$TAB" read -r v l; do
		[ -n "$v" ] || continue
		pick_vals[${#pick_vals[@]}]="$v"
		pick_labels[${#pick_labels[@]}]="$l"
	done <<-ITEMS
		$items
	ITEMS
	n=${#pick_vals[@]}
	[ "$n" -gt 0 ] || return 1
	PICK_RESULT=""
	while :; do
		term_size
		list_h=$((ROWS - 2))
		[ "$list_h" -ge 1 ] || list_h=1
		[ "$sel" -ge "$ptop" ] || ptop="$sel"
		[ "$sel" -lt $((ptop + list_h)) ] || ptop=$((sel - list_h + 1))
		[ "$ptop" -ge 0 ] || ptop=0
		{
			printf '\033[H\033[2J'
			printf '\033[1m%-*s\033[0m\n' "$COLS" "${title:0:$COLS}"
			end=$((ptop + list_h))
			[ "$end" -le "$n" ] || end="$n"
			i="$ptop"
			while [ "$i" -lt "$end" ]; do
				if [ "$kind" = multi ]; then
					mark=" "
					case " $pick_marked " in *" ${pick_vals[$i]} "*) mark="x" ;; esac
					l="$(printf ' [%s] %s' "$mark" "${pick_labels[$i]}")"
				else
					l="$(printf '  %s' "${pick_labels[$i]}")"
				fi
				if [ "$i" -eq "$sel" ]; then row "$l" sel; else row "$l"; fi
				i=$((i + 1))
			done
			i=$((end - ptop))
			while [ "$i" -lt "$list_h" ]; do
				row ""
				i=$((i + 1))
			done
			if [ "$kind" = multi ]; then
				footer="space mark  enter confirm  q cancel"
			else
				footer="enter select  q cancel"
			fi
			printf '\033[%d;1H\033[1m%-*s\033[0m' "$ROWS" "$COLS" "${footer:0:$COLS}"
		} 2>/dev/null
		readkey || return 1
		case "$KEY" in
		j) [ "$sel" -lt $((n - 1)) ] && sel=$((sel + 1)) || true ;;
		k) [ "$sel" -gt 0 ] && sel=$((sel - 1)) || true ;;
		g) sel=0 ;;
		G) sel=$((n - 1)) ;;
		' ')
			[ "$kind" = multi ] || continue
			v="${pick_vals[$sel]}"
			case " $pick_marked " in
			*" $v "*)
				kept=""
				for x in $pick_marked; do [ "$x" = "$v" ] || kept="$kept $x"; done
				pick_marked="$kept"
				;;
			*) pick_marked="$pick_marked $v" ;;
			esac
			;;
		'')
			if [ "$kind" = multi ]; then
				PICK_RESULT="$(printf '%s' "$pick_marked" | sed 's/  */ /g; s/^ //; s/ $//')"
			else
				PICK_RESULT="${pick_vals[$sel]}"
			fi
			return 0
			;;
		q | ESC) return 1 ;;
		esac
	done
}

# $EDITOR owns the whole terminal while it runs, so hand it a normal screen
# and take the alternate one back afterwards.
run_external() {
	raw_off
	"$@" || true
	raw_on
}

no_task() {
	MSG="epic header selected -- no task here"
}

edit_body() {
	local ti
	ti="$(cur_task)"
	[ -n "$ti" ] || {
		no_task
		return 0
	}
	run_external "${EDITOR:-vi}" "$(task_path "$ti")"
	MSG="edited ${ids[$ti]}"
	DETAIL_FOR=""
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
	local out ti
	ti="$(cur_task)"
	[ -n "$ti" ] || {
		no_task
		return 0
	}
	if confirm "delete \"${titles[$ti]}\"?"; then
		if out="$(backlog remove "${ids[$ti]}" 2>&1)"; then
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
	local current next first pick out ti
	ti="$(cur_task)"
	[ -n "$ti" ] || {
		no_task
		return 0
	}
	current="${cats[$ti]}"
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
	if out="$(backlog set-category "${ids[$ti]}" "$pick" 2>&1)"; then
		MSG="$out"
	else
		MSG="set-category failed: $out"
	fi
	load
}

retitle_task() {
	local out ti
	ti="$(cur_task)"
	[ -n "$ti" ] || {
		no_task
		return 0
	}
	prompt "new title (was \"${titles[$ti]}\"): "
	[ -n "$REPLY_LINE" ] || {
		MSG="retitle cancelled"
		return 0
	}
	if out="$(backlog retitle "${ids[$ti]}" "$REPLY_LINE" 2>&1)"; then
		MSG="$out"
	else
		MSG="retitle failed: $out"
	fi
	load
}

# The four setters below share one contract: a rejected change sets MSG and
# skips load(), so SEL/TOP/COLLAPSED keep their values and the footer shows the
# CLI's own die message instead of looking like a no-op.
set_priority_task() {
	local out ti value
	ti="$(cur_task)"
	[ -n "$ti" ] || {
		no_task
		return 0
	}
	prompt "priority for ${ids[$ti]} (empty clears, higher wins): "
	value="$REPLY_LINE"
	# set-priority has no empty-value form: an empty 3rd arg dies on the usage line.
	[ -n "$value" ] || value="--none"
	if out="$(backlog set-priority "${ids[$ti]}" "$value" 2>&1)"; then
		MSG="$out"
		load
	else
		MSG="set-priority failed: $out"
	fi
}

edit_deps_task() {
	local out ti cands marked csv
	ti="$(cur_task)"
	[ -n "$ti" ] || {
		no_task
		return 0
	}
	# A fresh list, not the in-memory ids: $FILTER must not hide a legal dependency.
	cands="$(backlog list 2>/dev/null |
		awk -F"$TAB" -v me="${ids[$ti]}" '$1 != "" && $1 != me { printf "%s\t%s -- %s\n", $1, $1, $3 }')"
	[ -n "$cands" ] || {
		MSG="no other task to depend on"
		return 0
	}
	marked="$(printf '%s' "${deps[$ti]}" | tr ',' ' ')"
	pick multi "depends_on for ${ids[$ti]}  (space toggles)" "$cands" "$marked" || {
		MSG="deps cancelled"
		return 0
	}
	csv="$(printf '%s' "$PICK_RESULT" | tr ' ' ',')"
	[ -n "$csv" ] || csv="--none"
	if out="$(backlog set-deps "${ids[$ti]}" "$csv" 2>&1)"; then
		MSG="$out"
		load
	else
		MSG="set-deps failed: $out"
	fi
}

move_epic_task() {
	local out ti cands epics_out e
	ti="$(cur_task)"
	[ -n "$ti" ] || {
		no_task
		return 0
	}
	epics_out="$(backlog epics 2>/dev/null || true)"
	if [ -z "$epics_out" ] && [ -z "${epics[$ti]}" ]; then
		MSG="no epics yet -- press E to create one"
		return 0
	fi
	cands="--none${TAB}(none) -- move out of any epic"
	for e in $epics_out; do
		cands="$cands
$e${TAB}epic: $e"
	done
	pick single "epic for ${ids[$ti]}" "$cands" || {
		MSG="epic move cancelled"
		return 0
	}
	if out="$(backlog epic-move "${ids[$ti]}" "$PICK_RESULT" 2>&1)"; then
		MSG="$out"
		load
	else
		MSG="epic-move failed: $out"
	fi
}

# The epic exists before the editor runs, so an editor that writes nothing
# leaves a real epic with an empty description -- epic-remove is the undo.
new_epic() {
	local out epic desc
	prompt "new epic id (slug, empty cancels): "
	epic="$REPLY_LINE"
	[ -n "$epic" ] || {
		MSG="new epic: cancelled"
		return 0
	}
	if ! out="$(backlog epic-add "$epic" 2>&1)"; then
		MSG="epic-add failed: $out"
		return 0
	fi
	desc="$BACKLOG_TASKS_DIR/$epic/DESCRIPTION.md"
	run_external "${EDITOR:-vi}" "$desc"
	if [ -s "$desc" ]; then
		MSG="created epic $epic"
	else
		MSG="created epic $epic -- description left empty"
	fi
}

view_task() {
	[ "$N" -gt 0 ] || return 0
	ensure_detail
	run_external "${PAGER:-less}" "$DETAIL_FILE"
}

help_screen() {
	printf '\033[H\033[2J'
	cat <<-KEYS
		radin tui keys

		  j / down      next task
		  k / up        previous task
		  g / G         first / last task
		  enter, e      edit the task body in \$EDITOR (an epic row: collapse/expand)
		  v             view the composed detail (body, epic, plans, priority, deps) in \$PAGER
		  Tab           the Done view: completed tasks and their commits (read-only)
		  n             new task (category, title, then body in \$EDITOR)
		  d             delete the selected task (asks first)
		  c             move the task to the next category
		  r             retitle the task (its id never changes)
		  p             set priority (empty input clears it; higher wins)
		  D             edit depends_on: pick from the other tasks, space toggles
		  m             move the task into an epic, or out of one
		  E             create an epic, then write its DESCRIPTION.md in \$EDITOR
		  /             filter by id or title (empty clears)
		  R             reload from disk
		  q             quit

		Row colour is the priority band, relative to the priorities now shown:
		red highest third, yellow middle, green lowest, no colour when unset.
		Set NO_COLOR to a non-empty value to turn it off.
		A P in the first column marks a task radin-plan has already planned.
		Epic rows are headers; collapse is per-session.
		Tasks live in .claude/.radin/backlog/ in this repo.

		press any key
	KEYS
	readkey || true
}

eval "$(backlog env)"
BACKLOG_DIR="${BACKLOG_INDEX%/*}"

DETAIL_FILE="$(mktemp)"
trap 'cleanup' EXIT
raw_on
load

while :; do
	if [ "$MODE" = "done" ]; then draw_done; else draw; fi
	MSG=""
	readkey || break
	if [ "$MODE" = "done" ]; then
		case "$KEY" in
		j) [ "$DONE_SEL" -lt $((DONE_N - 1)) ] && DONE_SEL=$((DONE_SEL + 1)) || true ;;
		k) [ "$DONE_SEL" -gt 0 ] && DONE_SEL=$((DONE_SEL - 1)) || true ;;
		g) DONE_SEL=0 ;;
		G) [ "$DONE_N" -eq 0 ] || DONE_SEL=$((DONE_N - 1)) ;;
		"$TAB") MODE="list" ;;
		R)
			load_done
			MSG="reloaded"
			;;
		'?') help_screen ;;
		q) break ;;
		*) ;;
		esac
		continue
	fi
	case "$KEY" in
	j) [ "$SEL" -lt $((N - 1)) ] && SEL=$((SEL + 1)) || true ;;
	k) [ "$SEL" -gt 0 ] && SEL=$((SEL - 1)) || true ;;
	g) SEL=0 ;;
	G) [ "$N" -eq 0 ] || SEL=$((N - 1)) ;;
	e | '') if [ -n "$(cur_task)" ]; then edit_body; else toggle_collapse; fi ;;
	v) view_task ;;
	"$TAB")
		MODE="done"
		load_done
		;;
	n) new_task ;;
	d) delete_task ;;
	c) cycle_category ;;
	r) retitle_task ;;
	p) set_priority_task ;;
	D) edit_deps_task ;;
	m) move_epic_task ;;
	E) new_epic ;;
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
