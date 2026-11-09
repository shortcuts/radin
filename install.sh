#!/bin/sh
# Fetches the radin release installer, then runs `radin install` with the same flags.
# Old `radin update` copies download this path, so it must keep accepting their flags.
set -eu

url="${RADIN_INSTALLER_URL:-https://github.com/shortcuts/radin/releases/latest/download/radin-installer.sh}"

command -v curl >/dev/null 2>&1 || {
	echo "radin: curl not found -- install curl, then re-run." >&2
	exit 1
}
tmp="$(mktemp)"
curl -fsSL "$url" -o "$tmp" || {
	rm -f "$tmp"
	echo "radin: could not download $url" >&2
	exit 1
}
sh "$tmp"
rm -f "$tmp"

bin="${CARGO_HOME:-$HOME/.cargo}/bin/radin"
yes=""
for a in "$@"; do
	[ "$a" != --yes ] || yes=1
done
# Under `curl | sh` stdin is the script, so the wizard reads the terminal instead.
if [ ! -t 0 ] && [ -z "$yes" ] && (: </dev/tty) 2>/dev/null; then
	exec "$bin" install "$@" </dev/tty
fi
exec "$bin" install "$@"
