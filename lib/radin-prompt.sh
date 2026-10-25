#!/usr/bin/env bash
# Assembles one radin-batch sub-agent prompt, so the router never reads the
# template file, never substitutes a placeholder, and never sends a leaf the
# steps its task does not have. Installed to ~/.claude/.radin/lib/radin-prompt.sh
# by install.sh.
#
# Usage:
#   radin-prompt.sh planning  <id>
#   radin-prompt.sh execution <id>
#   radin-prompt.sh debug     <id> <failure reason>
#   radin-prompt.sh factfind  <id> <question>
#   radin-prompt.sh gate
#   radin-prompt.sh merge
#
# Writes the prompt to <namespace>/state/prompts/<id>-<kind>.md and prints
# `model<TAB><name>` and `prompt<TAB><path>`. The router dispatches the path,
# never the text: echoing a whole prompt back as a Task argument costs output
# tokens on every dispatch. Exit 1 on a bad kind, an unresolvable id, or an
# unresolved dependency.
#
# One template per kind, radin-prompt-<kind>.md: a single fenced prompt, guarded
# blocks marked `<!-- if:NAME -->`/`<!-- if:!NAME -->` … `<!-- end -->`, and the
# role's model on a `model: "<name>"` line, written in at install time. Only the
# fence reaches the sub-agent; the prose around it is for its editor. One file
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
if [ -z "$kind" ] || { [ -z "$id" ] && [ "$kind" != gate ] && [ "$kind" != merge ]; }; then
	die "usage: radin-prompt.sh <planning|execution|debug|factfind> <id> [<failure|question>] | gate | merge"
fi

case "$kind" in
planning | execution | debug | factfind | gate | merge) ;;
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

fence() {
	awk '
		/^```$/ { fence = !fence; next }
		fence { print }
	' "$1"
}

body="$(fence "$TEMPLATE")"
[ -n "$body" ] || die "no fenced prompt in $TEMPLATE"
leaf_contract="$(fence "$LIB_DIR/radin-leaf-contract.md")"
[ -n "$leaf_contract" ] || die "no fenced contract in $LIB_DIR/radin-leaf-contract.md"
comment_rule="$(fence "$LIB_DIR/radin-comment-rule.md")"
[ -n "$comment_rule" ] || die "no fenced rule in $LIB_DIR/radin-comment-rule.md"
explore_rule="$(fence "$LIB_DIR/radin-explore-rule.md")"
[ -n "$explore_rule" ] || die "no fenced rule in $LIB_DIR/radin-explore-rule.md"
open_decisions_rule="$(fence "$LIB_DIR/radin-open-decisions.md")"
[ -n "$open_decisions_rule" ] || die "no fenced rule in $LIB_DIR/radin-open-decisions.md"

# One `eval` of the CLI's own export lines, rather than parsing them: the
# namespace is this script's only input that is not an argument.
eval "$(bash "$LIB_DIR/radin-backlog.sh" env --export)"

# Placeholder substitution, longest name first where one contains another.
sub_token() {
	# $1 token, $2 value: parameter expansion, so a multi-line value (the
	# ACCEPTANCE block) lands whole and no sed metacharacter is special.
	body="${body//$1/$2}"
}

# The gate belongs to the session, not a task: no id, no task fields, no guards.
if [ "$kind" = gate ]; then
	commits="$(cd "$REPO_ROOT" && bash "$LIB_DIR/radin-state.sh" session-commits)" ||
		die "no session commits, so no gate is due"
	sub_token LEAF_CONTRACT "$leaf_contract"
	sub_token SESSION_COMMITS "$(printf '%s\n' "$commits" | awk 'NF { printf "%s%s", sep, $0; sep = " " } END { print "" }')"
	mkdir -p "$NAMESPACE_DIR/state/prompts"
	out="$NAMESPACE_DIR/state/prompts/session-gate.md"
	printf '%s\n' "$body" >"$out"
	printf 'model\t%s\nprompt\t%s\n' "$model" "$out"
	exit 0
fi

# Like the gate, the merge belongs to the session. `merge-list` names the base
# branch and the task branches, so the leaf never derives either from git.
if [ "$kind" = merge ]; then
	list="$(cd "$REPO_ROOT" && bash "$LIB_DIR/radin-state.sh" merge-list)" ||
		die "no session branch is left to merge"
	sub_token LEAF_CONTRACT "$leaf_contract"
	sub_token MERGE_BASE "$(printf '%s\n' "$list" | sed -n 's/^base\t//p')"
	sub_token MERGE_BRANCHES "$(printf '%s\n' "$list" | awk -F'\t' '$1 != "base" { printf "%s%s (%s)", sep, $2, $3; sep = ", " } END { print "" }')"
	mkdir -p "$NAMESPACE_DIR/state/prompts"
	out="$NAMESPACE_DIR/state/prompts/session-merge.md"
	printf '%s\n' "$body" >"$out"
	printf 'model\t%s\nprompt\t%s\n' "$model" "$out"
	exit 0
fi

field() {
	(cd "$REPO_ROOT" && bash "$LIB_DIR/radin-backlog.sh" field "$id" "$1" 2>/dev/null)
}

task_id="$(field TASK_ID)" || die "no backlog task matches: $id"
[ -n "$task_id" ] || die "no backlog task matches: $id"
task_file="$(field TASK_FILE)"
category="$(field CATEGORY)"
# Category says what the change does to the codebase, not how hard it is: a
# chore can still need tuning on a device. Only the planner's read of the code
# marks a task low, and an unsized task keeps the execution model.
if [ "$kind" = execution ] && [ "$(field COMPLEXITY || true)" = low ]; then
	# shellcheck disable=SC2016
	low_model="$(sed -n 's/^`model-low: "\([^"]*\)"`$/\1/p' "$TEMPLATE" | head -1)"
	[ -n "$low_model" ] || die "no model-low line in $TEMPLATE"
	model="$low_model"
fi

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

# Commits landed since the plan was written that touched its `## Changes`
# paths. The sidecar is written by `add-plan`; no sidecar or an unknown hash
# (history rewrite) means no block.
stale_plan=""
head_file="$NAMESPACE_DIR/plans/$task_id.head"
if [ "$kind" = execution ] && [ -f "$head_file" ]; then
	base="$(cat "$head_file")"
	if git -C "$REPO_ROOT" cat-file -e "$base^{commit}" 2>/dev/null; then
		plan_files="$(cd "$REPO_ROOT" && bash "$LIB_DIR/radin-backlog.sh" files "$task_id" 2>/dev/null)" || plan_files=""
		hit=""
		if [ -n "$plan_files" ]; then
			hit="$(git -C "$REPO_ROOT" diff --name-only "$base" HEAD 2>/dev/null |
				grep -Fx -f <(printf '%s\n' "$plan_files") || true)"
		fi
		if [ -n "$hit" ]; then
			hit_args=()
			while IFS= read -r hit_path; do hit_args[${#hit_args[@]}]="$hit_path"; done <<-HIT
				$hit
			HIT
			commits="$(git -C "$REPO_ROOT" log --format='%h %s' "$base..HEAD" -- "${hit_args[@]}" |
				awk 'NF { printf "%s%s", sep, $0; sep = "; " }')"
			files="$(printf '%s\n' "$hit" | awk 'NF { printf "%s%s", sep, $0; sep = ", " }')"
			[ -z "$commits" ] || stale_plan="$commits | files: $files"
		fi
	fi
fi

task_dir=""
if [ "$kind" = debug ]; then
	task_dir="$(bash "$LIB_DIR/radin-state.sh" task-dir "$task_id")"
fi

# Drops every guarded block whose name is not in the active list (see below).
strip_guards() {
	awk -v active="$1" '
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
	'
}

# Guard names active for this task. A `<!-- if:NAME -->` block survives only
# when its name is listed here, and `<!-- if:!NAME -->` only when it is not.
active=" CAT_$category "
[ -z "$plan_paths" ] || active="$active PLAN_PATHS "
# A planning dispatch for an unflagged or already-planned entry only sizes it.
[ -n "$plan_paths" ] || ! field PLANNING >/dev/null || active="$active NEEDS_PLAN "
[ -z "$skills" ] || active="$active SKILLS "
[ -z "$acceptance" ] || active="$active ACCEPTANCE "
[ -z "$facts" ] || active="$active FACTS "
[ -z "$location" ] || active="$active LOCATION "
[ -z "$epic_context" ] || active="$active EPIC_CONTEXT "
[ -z "$depends_on" ] || active="$active DEPENDS_ON "
[ -z "$stale_plan" ] || active="$active STALE_PLAN "
[ -z "$depends_on$stale_plan" ] || active="$active DRIFT "

body="$(printf '%s\n' "$body" | strip_guards "$active")"

review_core=""
if [ "$kind" = execution ]; then
	review_core="$(strip_guards " LEVEL_diff " <"$LIB_DIR/radin-review-core.md")"
fi

sub_token LEAF_CONTRACT "$leaf_contract"
sub_token COMMENT_RULE "$comment_rule"
sub_token EXPLORE_RULE "$explore_rule"
sub_token OPEN_DECISIONS_RULE "$open_decisions_rule"
sub_token NAMESPACE_DIR "$NAMESPACE_DIR"
sub_token TASK_FILE "$task_file"
sub_token TASK_DIR "$task_dir"
sub_token TASK_ID "$task_id"
sub_token PLAN_PATHS "${plan_paths:-none}"
sub_token DEPENDS_ON "${depends_on:-none}"
sub_token STALE_PLAN "${stale_plan:-none}"
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
sub_token REVIEW_CORE "$review_core"
sub_token EPIC_CONTEXT "$epic_context"
sub_token TASK_BODY "$task_body"

mkdir -p "$NAMESPACE_DIR/state/prompts"
out="$NAMESPACE_DIR/state/prompts/$task_id-$kind.md"
printf '%s\n' "$body" >"$out"
printf 'model\t%s\nprompt\t%s\n' "$model" "$out"
