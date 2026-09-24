#!/usr/bin/env bash
# radin update: refresh radin itself by re-running install.sh in --update mode
# (radin's own steps and questions, no companion installer).
# Installed to ~/.claude/.radin/lib/radin-update.sh by install.sh.
#
# Usage: radin update [--yes]
# Must stay bash-3.2-compatible (macOS /bin/bash).
set -euo pipefail

ROOT_FILE="$HOME/.claude/.radin/install_root"
INSTALLER_URL="https://raw.githubusercontent.com/shortcuts/radin/main/install.sh"

SRC=""
[ -f "$ROOT_FILE" ] && SRC="$(cat "$ROOT_FILE")"

if [ -n "$SRC" ] && [ -d "$SRC/.git" ]; then
	# A dev clone is the user's own working tree: pull only when it is clean and
	# fast-forwardable, so an update never lands on top of local work.
	if [ -n "$(git -C "$SRC" status --porcelain)" ]; then
		printf 'radin update: %s has uncommitted changes -- commit or stash them, then re-run.\n' "$SRC" >&2
		exit 1
	fi
	printf 'radin update: pulling %s\n' "$SRC"
	git -C "$SRC" pull --ff-only
	exec bash "$SRC/install.sh" --update "$@"
fi

# Tarball install, or an install predating $ROOT_FILE. install.sh re-downloads
# the newest release into its own fetch dir, so fetch the newest installer too
# rather than re-running whatever version is on disk.
command -v curl >/dev/null 2>&1 || {
	printf 'radin update: curl not found -- install curl, then re-run.\n' >&2
	exit 1
}
TMP_INSTALLER="$(mktemp)"
curl -fsSL "$INSTALLER_URL" -o "$TMP_INSTALLER"
bash "$TMP_INSTALLER" --update "$@"
rm -f "$TMP_INSTALLER"
