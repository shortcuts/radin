#!/usr/bin/env bash
# Moves the legacy per-host state directories (<repo>/.claude/.radin and
# <repo>/.agents/.radin) into <repo>/.radin, and adds .radin/ to .gitignore once.
# Sourced by radin-namespace.sh on the run that finds no <repo>/.radin. Not meant to run on its own.
# Must stay bash-3.2-compatible (macOS /bin/bash).

# shellcheck disable=SC1091
. "${BASH_SOURCE[0]%/*}/radin-json.sh"

MIG_TRACKED=""
MIG_TAKEN=""
MIG_MAP=""

mig_taken() {
	case "$MIG_TAKEN" in *"
$1
"*) return 0 ;; esac
	return 1
}

mig_ensure_newline() {
	[ ! -s "$1" ] || [ -z "$(tail -c1 "$1")" ] || printf '\n' >>"$1"
}

# Prints the renamed basename of relpath $1 when it belongs to id $2, renamed to $3.
mig_newname() {
	local base=${1##*/}
	case "$1" in
	backlog/tasks/*)
		case "$base" in "$2".*) printf '%s\n' "$3${base#"$2"}" ;; *) return 1 ;; esac
		;;
	plans/* | state/facts/*)
		case "$base" in "$2".md | "$2"-[0-9]*.md) printf '%s\n' "$3${base#"$2"}" ;; *) return 1 ;; esac
		;;
	state/prompts/*)
		case "$base" in
		"$2"-execution.md | "$2"-planning.md | "$2"-gate.md | "$2"-merge.md | "$2"-debug.md | "$2"-factfind.md)
			printf '%s\n' "$3${base#"$2"}"
			;;
		*) return 1 ;;
		esac
		;;
	*) return 1 ;;
	esac
}

# Appends the incoming index $2 to the stage index $1; id collisions get an -agents suffix.
mig_merge_index() {
	local dst=$1 src=$2 line id n new old
	[ -s "$src" ] || return 0
	MIG_TAKEN="
"
	MIG_MAP=""
	if [ -s "$dst" ]; then
		while IFS= read -r line || [ -n "$line" ]; do
			MIG_TAKEN="$MIG_TAKEN$(json_get id "$line")
"
		done <"$dst"
	fi
	local incoming="
"
	while IFS= read -r line || [ -n "$line" ]; do
		incoming="$incoming$(json_get id "$line")
"
	done <"$src"
	while IFS= read -r line || [ -n "$line" ]; do
		id=$(json_get id "$line")
		mig_taken "$id" || continue
		new="$id-agents" n=2
		while mig_taken "$new" || case "$incoming" in *"
$new
"*) true ;; *) false ;; esac do
			new="$id-agents-$n"
			n=$((n + 1))
		done
		MIG_TAKEN="$MIG_TAKEN$new
"
		MIG_MAP="$MIG_MAP$id $new
"
	done <"$src"
	mig_ensure_newline "$dst"
	while IFS= read -r line || [ -n "$line" ]; do
		id=$(json_get id "$line")
		while read -r old new; do
			[ -n "$old" ] || continue
			line=$(printf '%s' "$line" | sed -e "s#\"$old\"#\"$new\"#g")
			if [ "$old" = "$id" ]; then
				line=$(printf '%s' "$line" | sed -E -e "s#/$old(\.md|-[0-9]+\.md)\"#/$new\1\"#g")
			fi
		done <<MAP
$MIG_MAP
MAP
		printf '%s\n' "$line" >>"$dst"
	done <"$src"
}

mig_copy_renamed() {
	local src=$1 dst=$2 old new rel nb
	while read -r old new; do
		[ -n "$old" ] || continue
		(cd "$src" && find backlog/tasks plans state/facts state/prompts -type f 2>/dev/null) | while IFS= read -r rel; do
			nb=$(mig_newname "$rel" "$old" "$new") || continue
			mkdir -p "$dst/${rel%/*}"
			cp "$src/$rel" "$dst/${rel%/*}/$nb"
		done
	done <<MAP
$MIG_MAP
MAP
}

mig_append() {
	[ -s "$1" ] || return 0
	mig_ensure_newline "$2"
	cat "$1" >>"$2"
}

mig_merge() {
	local src=$1 dst=$2
	mig_merge_index "$dst/backlog/index.jsonl" "$src/backlog/index.jsonl"
	mig_copy_renamed "$src" "$dst"
	mig_append "$src/state/completed.json" "$dst/state/completed.json"
	mig_append "$src/state/journal.jsonl" "$dst/state/journal.jsonl"
	# -n keeps the target's file, so session files and every taken path stay as they are.
	cp -Rn "$src/." "$dst/" 2>/dev/null || true
}

mig_retire() {
	local src=$1 dest
	dest="${src}.migrated"
	[ ! -e "$dest" ] || dest="${dest}.$(date +%s)"
	if [ -n "$(git -C "$2" ls-files -- "${src#"$2"/}" 2>/dev/null)" ]; then
		git -C "$2" mv "${src#"$2"/}" "${dest#"$2"/}"
	else
		mv "$src" "$dest"
	fi
}

migrate_state() {
	local root=$1 stage="$1/.radin.migrating" legacy="" d i first="" second=""
	if [ -n "$(git -C "$root" ls-files -- .radin .claude/.radin .agents/.radin 2>/dev/null)" ]; then MIG_TRACKED=1; fi
	[ ! -d "$root/.claude/.radin" ] || legacy="$root/.claude/.radin"
	[ ! -d "$root/.agents/.radin" ] || legacy="$legacy $root/.agents/.radin"
	[ -n "$legacy" ] || return 0

	if ! mkdir "$stage" 2>/dev/null; then
		i=0
		while [ ! -e "$root/.radin" ] && [ "$i" -lt 50 ]; do
			sleep 0.1
			i=$((i + 1))
		done
		[ ! -e "$root/.radin" ] || return 0
		mv "$stage" "$stage.$(date +%s)" 2>/dev/null || true
		mkdir "$stage" 2>/dev/null || {
			printf 'radin: migration in progress\n' >&2
			return 1
		}
	fi

	for d in $legacy; do
		if [ -z "$first" ]; then first=$d; else second=$d; fi
	done
	cp -R "$first/." "$stage/" || {
		printf 'radin: cannot copy %s\n' "$first" >&2
		return 1
	}
	[ -z "$second" ] || mig_merge "$second" "$stage"
	if [ -s "$stage/backlog/index.jsonl" ]; then
		sed -e 's#/\.claude/\.radin/#/.radin/#g' -e 's#/\.agents/\.radin/#/.radin/#g' "$stage/backlog/index.jsonl" >"$stage/backlog/index.jsonl.tmp" &&
			mv "$stage/backlog/index.jsonl.tmp" "$stage/backlog/index.jsonl"
	fi
	if [ -e "$root/.radin" ]; then
		mv "$stage" "$stage.$(date +%s)"
		return 0
	fi
	mv "$stage" "$root/.radin"
	for d in $legacy; do mig_retire "$d" "$root"; done
}

ignore_state() {
	local gi="$1/.gitignore"
	[ -n "$GIT_DIR_REL" ] || return 0
	[ "$MIG_TRACKED" != 1 ] || return 0
	! git -C "$1" check-ignore -q .radin 2>/dev/null || return 0
	mig_ensure_newline "$gi"
	printf '.radin/\n' >>"$gi"
	printf 'radin: added .radin/ to .gitignore; delete the line to track it\n' >&2
}
