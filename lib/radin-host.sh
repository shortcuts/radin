#!/usr/bin/env bash
# Maps RADIN_HOST to the repo directory that holds radin's state.
# Sourced by radin-namespace.sh, radin-stats.sh and the dispatcher.
# Must stay bash-3.2-compatible (macOS /bin/bash).
case "${RADIN_HOST:-claude}" in
claude) HOST_DIR=.claude ;;
agents) HOST_DIR=.agents ;;
*)
	printf "radin: unknown host '%s' (expected claude|agents)\n" "$RADIN_HOST" >&2
	exit 2
	;;
esac
