#!/usr/bin/env bash
# Usage: verify-hosts.sh [--install-missing] [--only opencode|codex]. Installs radin
# for one host at a time into a temp HOME, then asks that host's own CLI what it
# sees. No model call and no network: companion fetchers on PATH are stubs.
# Must stay bash-3.2-compatible (macOS /bin/bash).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
hosts="opencode codex"
install_missing=0
no_install=0 # test seam: check the caller's HOME and PATH, install nothing
fail=0
ran=0
work=""
OPENCODE_PKG="@opencode/cli@${VERIFY_OPENCODE_VERSION:-2.2.5}"
CODEX_PKG="@openai/codex@${VERIFY_CODEX_VERSION:-0.166.0}"
SKILLS="$(awk '$1=="skill" {print $2}' "$root/SHIPPED")"
TOKENS='@@skill:|RADIN_CLI|RADIN_LIB|RADIN_(MODEL|EFFORT|AGENT)_|<!-- host:|<!-- /host'

usage() {
	printf 'usage: verify-hosts.sh [--install-missing] [--only opencode|codex]\n' >&2
	exit 2
}

while [ $# -gt 0 ]; do
	case "$1" in
	--install-missing) install_missing=1 ;;
	--no-install) no_install=1 ;;
	--only)
		[ $# -ge 2 ] || usage
		case "$2" in opencode | codex) hosts="$2" ;; *) usage ;; esac
		shift
		;;
	*) usage ;;
	esac
	shift
done

bad() { # host what [detail]
	printf 'FAIL %s: %s\n' "$1" "$2"
	[ -z "${3:-}" ] || printf '%s\n' "$3" | sed 's/^/  /'
	fail=1
}

probe() { # cmd... ; macOS ships no timeout
	if command -v timeout >/dev/null 2>&1; then
		timeout 60 "$@" 2>&1 </dev/null
	else
		"$@" 2>&1 </dev/null
	fi
}

ensure_cli() { # host cli pkg
	command -v "$2" >/dev/null 2>&1 && return 0
	if [ "$install_missing" = 1 ]; then
		npm install --prefix "$work/npm" --no-audit --no-fund "$3" >"$work/npm-$1.log" 2>&1 ||
			{
				bad "$1" "npm install $3" "$(tail -n 5 "$work/npm-$1.log")"
				return 1
			}
		PATH="$work/npm/node_modules/.bin:$PATH"
		return 0
	fi
	printf 'SKIP %s: %s not on PATH\n' "$1" "$2"
	return 1
}

setup_host_env() { # host cli
	local h="$work/$1" stubs="$work/stubs" c
	mkdir -p "$h/home" "$h/proj" "$stubs"
	for c in curl wget brew mise npx npm gh pip pipx uv; do
		printf '#!/bin/sh\nexit 1\n' >"$stubs/$c"
		chmod +x "$stubs/$c"
	done
	export HOME="$h/home" XDG_CONFIG_HOME="$h/home/.config" CODEX_HOME="$h/home/.codex"
	unset OPENCODE_CONFIG CLAUDE_CONFIG_DIR
	PATH="$stubs:$(dirname "$(command -v "$2")"):$(dirname "$(command -v node)"):/usr/bin:/bin:/usr/sbin:/sbin"
	export PATH
	git -C "$h/proj" init -q
}

install_host() { # host
	local log="$work/install-$1.log"
	if ! bash "$root/install.sh" --yes --only "$1" </dev/null >"$log" 2>&1; then
		bad "$1" install "$(tail -n 15 "$log")"
		return 1
	fi
	if ! grep -qE "\"hosts\": *\[[^]]*\"$1\"" "$HOME/.radin/manifest.json" 2>/dev/null; then
		bad "$1" "install (host missing from manifest)" "$(grep -iE 'left out|RADIN_|survive' "$log" | head -n 5)"
		return 1
	fi
}

check_tokens() { # host path...
	local h="$1" hits
	shift
	hits="$(grep -rEn --include='*.md' "$TOKENS" "$@" 2>/dev/null || true)"
	[ -z "$hits" ] || bad "$h" "unresolved token" "$hits"
}

check_skills() { # host
	local s f
	for s in $SKILLS; do
		f="$HOME/.agents/skills/$s/SKILL.md"
		if [ "$(head -n 1 "$f" 2>/dev/null)" != "---" ] || ! grep -qxF "name: $s" "$f"; then
			bad "$1" "skill $s missing or malformed" "$f"
		fi
	done
}

verify_opencode() {
	local out k
	cd "$work/opencode/proj" 2>/dev/null || true
	out="$(probe opencode debug agents --standalone)" || bad opencode "debug agents exit" "$out"
	for k in planning execution review debug factfind gate merge; do
		printf '%s\n' "$out" | grep -qF "\"id\": \"radin-$k\"" || bad opencode "agent radin-$k missing"
	done
	out="$(probe opencode debug config --standalone)" || bad opencode "debug config exit" "$out"
	printf '%s\n' "$out" | grep -qF "$HOME/.radin/**" || bad opencode "external_directory rule missing"
	check_skills opencode
	check_tokens opencode "$HOME/.agents/skills" "$HOME/.radin/hosts/agents" \
		"$XDG_CONFIG_HOME/opencode/agents" "$XDG_CONFIG_HOME/opencode/AGENTS.md"
}

verify_codex() {
	local out s
	cd "$work/codex/proj" 2>/dev/null || true
	out="$(probe codex debug prompt-input)" || bad codex "debug prompt-input exit" "$out"
	for s in $SKILLS; do
		printf '%s\n' "$out" | grep -qF "$s" || bad codex "skill $s not listed"
	done
	printf '%s\n' "$out" | grep -qF "radin:begin" || bad codex "guidance block missing"
	printf '%s\n' "$out" | grep -qE "$TOKENS" && bad codex "unresolved token in prompt-input"
	out="$(probe "$HOME/.radin/bin/radin" doctor || true)"
	printf '%s\n' "$out" | grep -qF "OK       Codex lists radin skills" || bad codex "doctor: Codex skills listing" "$out"
	printf '%s\n' "$out" | grep -E "Codex hook" || true
	check_skills codex
	check_tokens codex "$HOME/.agents/skills" "$HOME/.radin/hosts/agents" "$CODEX_HOME/AGENTS.md"
}

work="$(mktemp -d)"
orig_path="$PATH"
trap 'rm -rf "$work"' EXIT
for host in $hosts; do
	case "$host" in opencode) pkg="$OPENCODE_PKG" ;; *) pkg="$CODEX_PKG" ;; esac
	before=$fail
	PATH="$orig_path"
	if [ "$no_install" = 1 ]; then
		mkdir -p "$work/$host/proj"
		command -v "$host" >/dev/null 2>&1 || {
			printf 'SKIP %s: %s not on PATH\n' "$host" "$host"
			continue
		}
	else
		ensure_cli "$host" "$host" "$pkg" || continue
		setup_host_env "$host" "$host"
		install_host "$host" || {
			ran=$((ran + 1))
			continue
		}
	fi
	ran=$((ran + 1))
	case "$host" in opencode) verify_opencode ;; *) verify_codex ;; esac
	[ "$fail" = "$before" ] && printf 'OK %s\n' "$host"
done
[ "$ran" -gt 0 ] || {
	echo "no host ran" >&2
	exit 1
}
exit "$fail"
