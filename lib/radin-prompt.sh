#!/usr/bin/env bash
# Assembles one radin-execute sub-agent prompt, so the router never reads the
# template file, never substitutes a placeholder, and never sends a leaf the
# steps its task does not have. Installed to ~/.claude/.radin/lib/radin-prompt.sh
# by install.sh.
#
# Usage:
#   radin-prompt.sh planning  <id>
#   radin-prompt.sh execution <id>
#   radin-prompt.sh debug     <id> <failure reason>
#   radin-prompt.sh factfind  <id> <question>
#
# Writes the prompt to <namespace>/state/prompts/<id>-<kind>.md and prints
# `model<TAB><name>` and `prompt<TAB><path>`. The router dispatches the path,
# never the text: echoing a whole prompt back as a Task argument costs output
# tokens on every dispatch. Exit 1 on a bad kind, an unresolvable id, or an
# unresolved dependency.
#
# One template per kind, radin-prompt-<kind>.md: a single fenced prompt, guarded
# blocks marked `<!-- if:NAME -->`/`<!-- if:!NAME -->` … `<!-- end -->`, and the
# role's model on a `model: "<name>"` line, written in at install time. One file
# per kind rather than one shared file, so a `---` line inside a prompt body
# cannot end the extraction. Nothing about a prompt's text lives here.
#
# Must stay bash-3.2-compatible (macOS /bin/bash).
set -euo pipefail

TAB="$(printf '\t')"

die() {
	printf 'radin-prompt: %s\n' "$*" >&2
	exit 1
}

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

kind="${1:-}"
id="${2:-}"
extra="${3:-}"
[ -n "$kind" ] && [ -n "$id" ] ||
	die "usage: radin-prompt.sh <planning|execution|debug|factfind> <id> [<failure|question>]"

case "$kind" in
planning | execution | debug | factfind) ;;
*) die "unknown prompt kind: $kind" ;;
esac
TEMPLATE="$LIB_DIR/radin-prompt-$kind.md"
[ -f "$TEMPLATE" ] || die "no template file: $TEMPLATE"

case "$kind" in
debug) [ -n "$extra" ] || die "the debug prompt needs the failure reason as its third argument" ;;
factfind) [ -n "$extra" ] || die "the factfind prompt needs the question as its third argument" ;;
esac

# shellcheck disable=SC2016  # the backticks are the template's markdown, not a subshell
model="$(sed -n 's/^`model: "\([^"]*\)"`$/\1/p' "$TEMPLATE" | head -1)"
[ -n "$model" ] || die "no model line in $TEMPLATE"

body="$(awk '
	/^```$/ { fence = !fence; next }
	fence { print }
' "$TEMPLATE")"
[ -n "$body" ] || die "no fenced prompt in $TEMPLATE"

# One `eval` of the CLI's own export lines, rather than parsing them: the
# namespace is this script's only input that is not an argument.
eval "$(bash "$LIB_DIR/radin-backlog.sh" env --export)"

field() {
	(cd "$REPO_ROOT" && bash "$LIB_DIR/radin-backlog.sh" field "$id" "$1" 2>/dev/null)
}

task_id="$(field TASK_ID)" || die "no backlog task matches: $id"
[ -n "$task_id" ] || die "no backlog task matches: $id"
task_file="$(field TASK_FILE)"
category="$(field CATEGORY)"

plan_paths=""
if plan_paths="$(field PLAN_PATHS)"; then :; else plan_paths=""; fi
skills=""
if skills="$(field SKILLS)"; then :; else skills=""; fi
if [ "$skills" = "none" ]; then
	skills=""
else
	# One instruction per line on the way in, one sentence in the prompt.
	skills="$(printf '%s\n' "$skills" | awk 'NF { printf "%s%s", sep, $0; sep = "; " } END { print "" }')"
fi
acceptance=""
if acceptance="$(field ACCEPTANCE)"; then :; else acceptance=""; fi
facts=""
if facts="$(field FACTS)"; then :; else facts=""; fi
location=""
if location="$(field LOCATION)"; then :; else location=""; fi
epic_context=""
if epic_context="$(field EPIC_CONTEXT)"; then :; else epic_context=""; fi
# `|| die`, not a bare assignment: `set -e` exits on a failing command
# substitution before any following check runs.
task_body="$(field TASK_BODY)" || die "task file is empty or missing: $task_file"

# Dependency commits are the router's old bookkeeping: `task-next` printed them
# and the prompt carried them by hand. deps-check is the same read, so the
# prompt gets them without the router holding a pair list.
depends_on=""
if [ "$kind" = execution ] && [ -f "$NAMESPACE_DIR/state/BACKLOG_STEPS.json" ]; then
	deps="$(bash "$LIB_DIR/radin-state.sh" deps-check "$task_id")" ||
		die "dependency of $task_id is unresolved, so no execution prompt is due yet"
	while IFS="$TAB" read -r dep hash; do
		[ -n "$dep" ] || continue
		[ -z "$depends_on" ] || depends_on="$depends_on, "
		depends_on="$depends_on$dep: $hash"
	done <<-DEPS
		$deps
	DEPS
fi

task_dir=""
if [ "$kind" = debug ]; then
	task_dir="$(bash "$LIB_DIR/radin-state.sh" task-dir "$task_id")"
fi

# Guard names active for this task. A `<!-- if:NAME -->` block survives only
# when its name is listed here, and `<!-- if:!NAME -->` only when it is not.
active=" CAT_$category "
[ -z "$plan_paths" ] || active="$active PLAN_PATHS "
[ -z "$skills" ] || active="$active SKILLS "
[ -z "$acceptance" ] || active="$active ACCEPTANCE "
[ -z "$facts" ] || active="$active FACTS "
[ -z "$location" ] || active="$active LOCATION "
[ -z "$epic_context" ] || active="$active EPIC_CONTEXT "
[ -z "$depends_on" ] || active="$active DEPENDS_ON "

body="$(printf '%s\n' "$body" | awk -v active="$active" '
	/^<!-- if:/ {
		name = $0
		sub(/^<!-- if:/, "", name); sub(/ -->$/, "", name)
		neg = (substr(name, 1, 1) == "!")
		if (neg) name = substr(name, 2)
		on = index(active, " " name " ") > 0
		skip = neg ? on : !on
		next
	}
	$0 == "<!-- end -->" { skip = 0; next }
	!skip { print }
')"

# Placeholder substitution, longest name first where one contains another.
sub_token() {
	# $1 token, $2 value: parameter expansion, so a multi-line value (the
	# ACCEPTANCE block) lands whole and no sed metacharacter is special.
	body="${body//$1/$2}"
}

sub_token NAMESPACE_DIR "$NAMESPACE_DIR"
sub_token TASK_FILE "$task_file"
sub_token TASK_DIR "$task_dir"
sub_token TASK_ID "$task_id"
sub_token PLAN_PATHS "${plan_paths:-none}"
sub_token DEPENDS_ON "${depends_on:-none}"
sub_token SKILLS "${skills:-none}"
sub_token CATEGORY "$category"
sub_token ACCEPTANCE "$acceptance"
sub_token FACTS "$facts"
sub_token LOCATION "$location"
case "$kind" in
debug) sub_token FAILURE "$extra" ;;
factfind) sub_token QUESTION "$extra" ;;
esac
# Last, because substitution is sequential: a body whose own prose mentions
# TASK_ID or NAMESPACE_DIR would otherwise be rewritten. Guard stripping
# already ran above, so an `<!-- if:NAME -->` line inside a body is inert.
sub_token EPIC_CONTEXT "$epic_context"
sub_token TASK_BODY "$task_body"

mkdir -p "$NAMESPACE_DIR/state/prompts"
out="$NAMESPACE_DIR/state/prompts/$task_id-$kind.md"
printf '%s\n' "$body" >"$out"
printf 'model\t%s\nprompt\t%s\n' "$model" "$out"
