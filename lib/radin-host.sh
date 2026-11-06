#!/usr/bin/env bash
# Validates RADIN_HOST (claude|agents), which selects skill names and the prompt render.
# Sourced by radin-scope.sh and the dispatcher.
# radin_skill NAME prints the host's spelling of a companion skill from skill-names-HOST.txt.
# Must stay bash-3.2-compatible (macOS /bin/bash).
case "${RADIN_HOST:-claude}" in
claude | agents) ;;
*)
	printf "radin: unknown host '%s' (expected claude|agents)\n" "$RADIN_HOST" >&2
	exit 2
	;;
esac

SKILL_NAMES_DIR=${BASH_SOURCE[0]%/*}
radin_skill() {
	local v
	v=$(awk -v k="$1" '$1 == k { sub(/^[^ \t]*[ \t]+/, ""); print; exit }' "$SKILL_NAMES_DIR/skill-names-${RADIN_HOST:-claude}.txt")
	[ -n "$v" ] || {
		printf "radin: unknown skill name '%s' for host '%s'\n" "$1" "${RADIN_HOST:-claude}" >&2
		return 1
	}
	printf '%s\n' "$v"
}
