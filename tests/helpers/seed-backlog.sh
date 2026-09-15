#!/usr/bin/env bash
# Builds a synthetic backlog of <n> tasks for `make bench`, entirely through
# the backlog CLI -- never by writing index.jsonl, so the fixture can never
# drift from the real store's shape.
#
# usage: seed-backlog.sh <repo-root> <n>
# Deterministic: same <n> always produces the same backlog.
# Must stay bash-3.2-compatible (macOS /bin/bash).
set -euo pipefail

root="${1:-}"
n="${2:-}"
[ -n "$root" ] && [ -n "$n" ] || {
	printf 'usage: seed-backlog.sh <repo-root> <n>\n' >&2
	exit 1
}
case "$n" in '' | *[!0-9]*)
	printf 'seed-backlog.sh: <n> must be a positive integer, got: %s\n' "$n" >&2
	exit 1
	;;
esac

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../lib" && pwd)"
BACKLOG="$LIB_DIR/radin-backlog.sh"

mkdir -p "$root"
root="$(cd "$root" && pwd)"
[ -d "$root/.git" ] || git -C "$root" init -q

bl() { (cd "$root" && bash "$BACKLOG" "$@"); }

printf 'synthetic epic\n' | bl epic-add epic-a >/dev/null

cats="feat fix chore refactor"
i=0
first_id=""
second_id=""
while [ "$i" -lt "$n" ]; do
	# shellcheck disable=SC2086  # word splitting is how the category cycles
	set -- $cats
	shift $((i % 4))
	cat="$1"
	epic=""
	[ $((i % 5)) -ne 0 ] || epic="--epic epic-a"
	# shellcheck disable=SC2086
	out="$(printf 'synthetic task body line one\nsynthetic task body line two\n' |
		bl add "$cat" "synthetic task $i" $epic --priority $((i * 3 % 97)))"
	id="${out#*(id: }"
	id="${id%%)*}"
	[ "$i" -ne 0 ] || first_id="$id"
	[ "$i" -ne 1 ] || second_id="$id"
	[ $((i % 7)) -ne 0 ] || bl add-plan "$id" "plans/$id.md" >/dev/null
	i=$((i + 1))
done

# One adversarial title, so every bench run also exercises the escaping path
# the awk field extractor has to survive.
printf 'escaping regression fixture\n' |
	bl add chore 'evil "file":"tasks/hack.md" and \"quote\" and back\slash' >/dev/null

if [ -n "$first_id" ] && [ -n "$second_id" ]; then
	printf 'dependent fixture task\n' | bl add feat 'synthetic dependent task' \
		--depends-on "$first_id,$second_id" >/dev/null
fi

printf 'seeded %s tasks in %s\n' "$(bl count)" "$root"
