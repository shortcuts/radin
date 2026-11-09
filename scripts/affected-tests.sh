#!/usr/bin/env bash
# Usage: scripts/affected-tests.sh [git-ref]. Prints the test files that cover the
# paths changed since <git-ref> (default HEAD) plus untracked ones, one per line.
# Prints ALL when a path has no narrow mapping, and nothing when no test applies.
# A dev-loop shortcut only: CI and the pre-commit gate run the full suite.
# Must stay bash-3.2-compatible (macOS /bin/bash).
set -euo pipefail
cd "$(dirname "$0")/.."
ref="${1:-HEAD}"

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
	install.sh) ls tests/install_upgrade.rs ;;
	src/install/plan.rs | src/install/publish.rs | src/install/assets.rs) echo tests/install_core.rs ;;
	src/install/wizard.rs | src/install/pick.rs | src/install/ui.rs) echo tests/install_wizard.rs ;;
	src/install/companions.rs | src/install/opencode.rs | src/install/cbm.rs) echo tests/install_companions.rs ;;
	src/install/home.rs | src/install/update.rs) echo tests/install_upgrade.rs ;;
	src/install/*) ls tests/install_*.rs ;;
	# The binary embeds and renders every one of these.
	SHIPPED | hosts/* | skills/* | lib/*.md | lib/*.txt | scripts/render-host.sh | scripts/golden-render.sh | tests/golden-claude-render.sha256)
		ls tests/install_core.rs tests/golden_render.rs tests/render-host.bats tests/host.bats
		;;
	lib/radin-*.sh | lib/radin-*.c)
		# The tests that name the file.
		grep -l -F "$(basename "$f")" tests/*.bats || true
		;;
	docs/* | *.md | .github/* | LICENSE | .gitignore | scripts/affected-tests.sh) ;;
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
