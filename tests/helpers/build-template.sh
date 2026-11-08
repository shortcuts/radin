#!/usr/bin/env bash
# Usage: build-template.sh DIR. Records one real install.sh run under DIR (home/, bin/,
# output, status) for every file that loads helpers/install to replay. `make test` builds
# it once and exports RADIN_TEMPLATE; a lone `bats` run builds its own in setup_file.
# Needs tests/helpers/mock (make build). Must stay bash-3.2-compatible.
set -euo pipefail
dir="$1"
root="$(cd "$(dirname "$0")/../.." && pwd)"
home="$dir/home"
bin="$dir/bin"
mkdir -p "$home" "$bin"
cp "$root/tests/helpers/mock" "$bin/mock"
# No cc link: this is the one run that compiles the TUI for real.
for c in brew curl claude npx python3 node gh; do
	ln "$bin/mock" "$bin/$c" 2>/dev/null || ln -s "$bin/mock" "$bin/$c"
done
st=0
# Same isolation as tests/helpers/isolate.bash; HOMEBREW_NO_AUTO_UPDATE would hide a leak.
(cd "$root" && printf '2\n' |
	env -u HOMEBREW_NO_AUTO_UPDATE -u OPENCODE_CONFIG -u CLAUDE_CONFIG_DIR -u OPENCODE \
		HOME="$home" XDG_CONFIG_HOME="$home/.config" CODEX_HOME="$home/.codex" \
		RADIN_DETAILS=1 MOCK_BIN="$bin" MOCK_LOG_DIR="$home" \
		PATH="$bin:/usr/bin:/bin:/usr/sbin:/sbin" \
		bash ./install.sh) >"$dir/output" 2>&1 || st=$?
printf '%s\n' "$st" >"$dir/status"
