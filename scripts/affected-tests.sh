#!/usr/bin/env bash
# Usage: scripts/affected-tests.sh [git-ref]. Prints the bats files that cover the
# paths changed since <git-ref> (default HEAD) plus untracked ones, one per line.
# Prints ALL when a path has no narrow mapping, and nothing when no test applies.
# A dev-loop shortcut only: CI and the pre-commit gate run the full suite.
# Must stay bash-3.2-compatible (macOS /bin/bash).
set -euo pipefail
cd "$(dirname "$0")/.."
ref="${1:-HEAD}"

# Every file that loads the recorded install replays or runs install.sh.
install_group() { grep -l 'helpers/install' tests/*.bats; }

changed="$(
	git diff --name-only "$ref" --
	git ls-files --others --exclude-standard
)"

out="$(mktemp)"
trap 'rm -f "$out"' EXIT

while IFS= read -r f; do
	[ -n "$f" ] || continue
	case "$f" in
	tests/*.bats) echo "$f" ;;
	tests/helpers/install.bash) install_group ;;
	lib/radin-tui.c) ls tests/tui-*.bats ;;
	# install.sh itself also drives the companion, update and uninstall tests.
	install.sh | bin/radin)
		grep -l -e 'helpers/install' -e 'install\.sh' -e 'bin/radin' tests/*.bats
		ls tests/render-host.bats tests/skill-names.bats tests/host.bats
		;;
	# install.sh copies and renders every one of these.
	SHIPPED | hosts/* | skills/* | lib/*.md | lib/*.txt | scripts/render-host.sh | scripts/golden-render.sh | tests/golden-claude-render.sha256)
		install_group
		ls tests/render-host.bats tests/skill-names.bats tests/host.bats
		;;
	lib/radin-*.sh | lib/radin-*.c)
		# The tests that name the file.
		grep -l -F "$(basename "$f")" tests/*.bats || true
		;;
	docs/* | *.md | .github/* | LICENSE | .gitignore | scripts/check-prose.sh | scripts/shipped.sh | scripts/affected-tests.sh) ;;
	*)
		echo ALL
		;;
	esac >>"$out"
done <<<"$changed"

if grep -qx ALL "$out"; then
	echo ALL
else
	sort -u "$out"
fi
