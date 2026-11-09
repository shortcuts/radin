#!/bin/sh
# Records a bash-era install into tests/fixtures/bash-era-home. Run by hand once:
# it needs commit aaa7f11, the last one with a bash installer.
# shellcheck disable=SC2016 # the stub bodies are literal sh, expanded when the stub runs
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/src" "$tmp/home" "$tmp/bin"
git -C "$root" archive aaa7f11 | tar -x -C "$tmp/src"

stub() { printf '#!/bin/sh\n%s\n' "$2" >"$tmp/bin/$1" && chmod +x "$tmp/bin/$1"; }
stub brew 'exit 0'
stub claude 'exit 0'
stub npx 'exit 0'
stub curl 'out=""; prev=""
for a in "$@"; do [ "$prev" = -o ] && out="$a"; prev="$a"; done
case "$out" in */SKILL.md|*/unslop|*/technical-writing) printf -- "---\nname: stub\n---\n" >"$out" ;; ?*) echo mock >"$out" ;; esac'
stub cc 'out=""; prev=""
for a in "$@"; do [ "$prev" = -o ] && out="$a"; prev="$a"; done
printf "#!/bin/sh\nexit 0\n" >"$out"; chmod +x "$out"'

(
	cd "$tmp/src"
	HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/home/.config" CODEX_HOME="$tmp/home/.codex" \
		PATH="$tmp/bin:/usr/bin:/bin" bash ./install.sh --yes --only claude,codex </dev/null
)

dest="$root/tests/fixtures/bash-era-home"
rm -rf "$dest"
mkdir -p "$dest"
cp -R "$tmp/home/.radin" "$dest/.radin"
cp -R "$tmp/home/.claude" "$dest/.claude"
[ -d "$tmp/home/.agents" ] && cp -R "$tmp/home/.agents" "$dest/.agents"
rm -rf "$dest/.radin/backups" "$dest/.claude/backups"
find "$dest" -name '*.log' -delete
