#!/usr/bin/env bash
# Deterministic backlog operations, so agents/skills don't hand-edit backlog
# storage. Installed to ~/.claude/.radin/lib/radin-backlog.sh by install.sh.
#
# Storage: $BACKLOG_INDEX is a JSONL file (one compact JSON object per line,
# one per task: {"id":...,"category":...,"title":...,"file":...}), plus the
# optional "priority":<1|2|3|5|8|13|21> and "depends_on":[<id>,...] keys a human
# sets.
# Each line's `file` field, relative to the backlog directory, is the
# authoritative location of that task's body (description prose, and any
# **Plan:** pointer lines radin-plan appends): `add` decides it, every other
# verb reads it back. Splitting each task into its own file means inserting a
# **Plan:** line into one task can never shift another task's content — unlike
# the old single-file BACKLOG.md, nothing here is ever addressed by line
# number.
#
# Usage:
#   radin-backlog.sh help [command]              # print every command's usage, or one command's
#   radin-backlog.sh env [--export]             # print REPO_ROOT/NAMESPACE_DIR/BACKLOG_INDEX/BACKLOG_TASKS_DIR (--export: source-able with export)
#   radin-backlog.sh show [category]             # print backlog as markdown, or one ## section
#   radin-backlog.sh list [--category <cat>] [--priority-min <n>] [--priority-max <n>] [--epic <epic-id>] [--order created|priority] [--planned] [--json]  # print "id<US>category<US>title<US>file<US>priority<US>depends-on-csv" (US = \037), priority-descending by default, unset priorities last (--order created gives index order; --planned appends a 7th P/empty field; --json prints the index lines instead)
#   radin-backlog.sh find <id-or-title>          # print matching "id<TAB>category<TAB>title<TAB>file<TAB>priority<TAB>depends-on-csv" line(s)
#   radin-backlog.sh count                       # print the number of entries (0 without an index)
#   radin-backlog.sh add <category> <title> [--epic <epic-id>] [--skill <name>]... [--priority <1|2|3|5|8|13|21>] [--depends-on <csv>]  # create task, body read from stdin, prints its id
#   radin-backlog.sh add-plan <id-or-title> <path>  # append "**Plan:** <path>" to the task's file
#   radin-backlog.sh append <id-or-title>        # append text from stdin to the task's file
#   radin-backlog.sh path <id-or-title>          # print the task file's absolute path
#   radin-backlog.sh plan-target <id-or-title> [<sub-slug>]  # resolve one task for planning: "id"/"title"/"task_file"/"plan_file" TAB lines plus one "plan<TAB><path>" per existing pointer; exit 1 no match, 2 several (candidates on stderr), 3 already planned
#   radin-backlog.sh set-category <id-or-title> <category>  # move a task to another category
#   radin-backlog.sh retitle <id-or-title> <title>  # change a task's title (its id never changes)
#   radin-backlog.sh set-priority <id-or-title> <1|2|3|5|8|13|21|--none>  # set/clear the priority (higher wins)
#   radin-backlog.sh set-deps <id-or-title> <csv-of-ids|--none>   # set/clear depends_on (rejects an unknown id and any cycle)
#   radin-backlog.sh meta <id-or-title>          # print "plan<TAB><path>" / "skill<TAB><instruction>" / "acceptance<TAB><criterion>" lines from the task's file
#   radin-backlog.sh planned                     # print the id of every task that already has a **Plan:** line
#   radin-backlog.sh order <--rank-needed|--report|--steps> [--rank <csv-of-ids>] [--infer-deps <id>=<csv>]... [--defer <csv-of-ids>]  # the execution order: the priority order with the topological dependency fix applied (--rank-needed: print every unset-priority id, exit 1 when there are none; --report: "<order>. <title> (id: <id>)" plus one "dependency override:" line per violated edge; --steps: "id<TAB>order<TAB>depends-on-csv<TAB>pending|deferred", which is `radin state steps-init`'s stdin format)
#   radin-backlog.sh field <id-or-title> <TASK_FILE|TASK_ID|CATEGORY|PLAN_PATHS|SKILLS|SKILLS_DROPPED|ACCEPTANCE>  # one Execution-prompt placeholder, rendered ready to substitute
#   radin-backlog.sh duplicates                  # print "id<TAB><value><TAB><ids>" / "title<TAB><value><TAB><ids>" per duplicated value, exit 1 when there are none
#   radin-backlog.sh remove <id-or-title>        # delete task file + index entry (exact single match required)
#   radin-backlog.sh reconcile <completed-file>  # drop backlog entries whose id is already in completed.json
#   radin-backlog.sh epics                       # print every epic id, one per line
#   radin-backlog.sh epic-add <epic-id>          # create the epic dir + DESCRIPTION.md (body from stdin when piped)
#   radin-backlog.sh epic-show <epic-id>         # print the epic's DESCRIPTION.md
#   radin-backlog.sh epic-move <id-or-title> <epic-id|--none>  # move a task into/out of an epic
#   radin-backlog.sh epic-remove <epic-id>       # delete an epic that has no child tasks left
#
# An epic is a directory under tasks/ holding DESCRIPTION.md (the root context
# every child task inherits) plus one file per child task. Membership is
# carried only by the index line's `file` field (`tasks/<epic-id>/<id>.md`),
# so an epic gets no index line of its own and no category: a consumer that
# forgot to filter epics out of `list` would dispatch one as a task.
# One nesting level: no epics inside epics.
#
# Priority is a human's call, so it is stored, not re-derived: higher is more
# important, gaps and duplicates are fine (inserting a task never forces a
# renumber), and an absent key means unset -- which must stay distinguishable
# from any number, because "did a human decide this?" is the question a
# prioritization pass has to answer. `depends_on` is human-authored ordering
# over task ids. Both live on the index line rather than in the task body, so
# sorting the backlog costs no file read per task.
#
# Categories: feat | fix | chore | refactor (canonical section order, used by `show`).
# `find` matches an exact id first, then exact title, then case-insensitive
# substring on title; multiple lines out means ambiguity the caller must resolve.
# Must stay bash-3.2-compatible (macOS /bin/bash).
set -euo pipefail

die() {
	printf 'radin-backlog: %s\n' "$*" >&2
	exit 1
}

# The header comment block above is the only usage text there is: `help`
# prints it back, and usage_die quotes one line of it, so a new subcommand can
# never ship undocumented and no hand-maintained second list can drift from it.
usage_lines() { sed -n 's|^#   radin-backlog\.sh |  |p' "${BASH_SOURCE[0]}"; }
usage_for() { usage_lines | grep -E "^  $1( |$)" || true; }
usage_die() {
	printf 'radin-backlog: %s\n' "$2" >&2
	usage_for "$1" >&2
	exit 1
}

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$LIB_DIR/radin-json.sh"
# Sourced, not `eval "$(bash ...)"`: the fork was ~12ms of every CLI call, and
# the skills make hundreds of them.
# shellcheck disable=SC1091
. "$LIB_DIR/radin-namespace.sh"

require_index() {
	[ -s "$BACKLOG_INDEX" ] || die "no backlog at $BACKLOG_INDEX"
}

TAB="$(printf '\t')"
# `list` separates with US, not TAB: TAB is IFS whitespace, so an unset
# priority collapses under `IFS=$TAB read` and shifts depends_on into it.
US="$(printf '\037')"

# One awk pass per read verb replaces the fork-per-JSON-field json_get loops
# that made `list` cost 5.5s on a 200-task backlog. Assembled by string
# concatenation: this prelude plus one per-verb body, which works the same on
# BWK awk, gawk and mawk. Every caller-supplied string reaches awk through
# ENVIRON, never `awk -v` -- `-v` interprets backslash escapes in the value, so
# a title carrying a backslash would arrive mangled.
#
# jstr/jraw are awk's copy of json_get/json_get_raw and must stay byte-identical
# to them: jstr walks the value after the `"key":"` needle one character at a
# time, consuming `\X` as a literal X and stopping at the first unescaped quote;
# jraw returns the raw integer or [...] array after `"key":`, empty when the key
# is absent, because unset must stay distinguishable from any value. A title
# containing a literal `"file":"` is stored escaped (`\"file\":\"`), so the
# needle cannot match inside it -- do not add a JSON tokenizer for that.
AWK_JSON='
BEGIN { US = sprintf("%c", 31); TAB = sprintf("%c", 9) }
function jstr(line, key,   s, out, c, i, n) {
  if (match(line, "\"" key "\":\"") == 0) return ""
  s = substr(line, RSTART + RLENGTH); out = ""; n = length(s)
  for (i = 1; i <= n; i++) { c = substr(s, i, 1)
    if (c == "\\") { i++; out = out substr(s, i, 1); continue }
    if (c == "\"") break
    out = out c }
  return out }
function jraw(line, key,   s) {
  if (match(line, "\"" key "\":") == 0) return ""
  s = substr(line, RSTART + RLENGTH)
  if (substr(s, 1, 1) == "[") {
    if (match(s, /^\[[^]]*\]/) == 0) return ""
    return substr(s, RSTART, RLENGTH) }
  if (match(s, /^-?[0-9]+/) == 0) return ""
  return substr(s, RSTART, RLENGTH) }
function depscsv(raw,   t) { t = raw; gsub(/[][" ]/, "", t); return t }
function fepic(f,   r) { if (f !~ /^tasks\/[^\/]+\//) return ""
                         r = substr(f, 7); sub(/\/.*$/, "", r); return r }
function row(line, sep) {
  return jstr(line, "id") sep jstr(line, "category") sep jstr(line, "title") \
         sep jstr(line, "file") sep jraw(line, "priority") \
         sep depscsv(jraw(line, "depends_on")) }
'

# `list`: filters and the sort keys in the same pass, so a filter costs no
# extra fork and two filters compose. The two leading keys are TAB-separated
# from the row because require_plain_title already rejects a tab in a title,
# so `cut -f3-` can never split a row.
# shellcheck disable=SC2016  # $0 is awk's record, not a shell expansion
AWK_LIST='
BEGIN { cat = ENVIRON["RADIN_CAT"]; epic = ENVIRON["RADIN_EPIC"]
        pmin = ENVIRON["RADIN_PMIN"]; pmax = ENVIRON["RADIN_PMAX"]
        json = ENVIRON["RADIN_JSON"]; plan = ENVIRON["RADIN_PLANNED"]
        dir = ENVIRON["RADIN_DIR"] }
$0 == "" { next }
{ if (cat != "" && jstr($0, "category") != cat) next
  if (epic != "" && fepic(jstr($0, "file")) != epic) next
  p = jraw($0, "priority")
  if (pmin != "" && (p == "" || p + 0 < pmin + 0)) next
  if (pmax != "" && (p == "" || p + 0 > pmax + 0)) next
  if (json != "") out = $0
  else {
    out = row($0, US)
    if (plan != "") {
      pf = dir "/" jstr($0, "file"); flag = ""
      while ((getline pl < pf) > 0)
        if (pl ~ /^\*\*Plan:\*\* /) { flag = "P"; break }
      close(pf)
      out = out US flag } }
  if (p == "") print "1" TAB "0" TAB out
  else print "0" TAB p TAB out }
'

# `matches`: the same three-tier contract as before (exact id, else exact
# title, else case-insensitive substring), in one pass instead of three.
# shellcheck disable=SC2016  # $0 is awk's record, not a shell expansion
AWK_MATCH='
BEGIN { q = ENVIRON["RADIN_Q"]; lq = tolower(q); n = 0 }
$0 == "" { next }
{ n++; lines[n] = $0; ids[n] = jstr($0, "id"); titles[n] = jstr($0, "title") }
END { hit = 0
  for (i = 1; i <= n; i++) if (ids[i] == q) { print lines[i]; hit = 1 }
  if (hit) exit
  for (i = 1; i <= n; i++) if (titles[i] == q) { print lines[i]; hit = 1 }
  if (hit) exit
  for (i = 1; i <= n; i++) if (index(tolower(titles[i]), lq) > 0) print lines[i] }
'

# `planned`: the index decides which file to read, never a glob over tasks/ --
# a filename-derived id would also match DESCRIPTION.md.
# shellcheck disable=SC2016  # $0 is awk's record, not a shell expansion
AWK_PLANNED='
BEGIN { dir = ENVIRON["RADIN_DIR"] }
$0 == "" { next }
{ f = dir "/" jstr($0, "file"); id = jstr($0, "id")
  while ((getline line < f) > 0)
    if (line ~ /^\*\*Plan:\*\* /) { print id; break }
  close(f) }
'

# `order`: the whole execution order in one pass -- the priority order `list`
# defaults to, plus the topological dependency fix, plus the three views the
# orchestrator needs. It exists so no prose has to sort, enumerate or pick:
# each mode's stdout is used as-is. It writes nothing: the index stays the
# human's, so an inferred rank or dependency reaches this verb as a flag and
# never a `set-priority`/`set-deps` call.
#
# Every caller string arrives through ENVIRON (never `awk -v`, same reason as
# above). RADIN_INFER carries the repeated --infer-deps pairs joined by US;
# ids are slugs, so neither `=` nor US can appear inside one.
# shellcheck disable=SC2016  # $0 is awk's record, not a shell expansion
AWK_ORDER='
function fail(msg) { printf("radin-backlog: %s\n", msg) > "/dev/stderr"; exit 1 }
# Sort predicate over the key triple: rank class (set priorities before unset),
# then priority (negated, so descending), then the tie-break -- index order, or
# --rank order inside the unset block. Same contract as AWK_LIST plus `sort`.
function less(a, b) {
  if (kc[a] != kc[b]) return kc[a] < kc[b]
  if (kp[a] != kp[b]) return kp[a] < kp[b]
  return ks[a] < ks[b] }
# DFS colouring over the effective dep graph: 1 = on the stack, 2 = done. The
# state array is shared across roots, which is what keeps it O(V+E).
function cyc(v, state,   j, m, d) {
  if (state[v] == 1) return 1
  if (state[v] == 2) return 0
  state[v] = 1
  m = split(eff[v], d, ",")
  for (j = 1; j <= m; j++) if (d[j] != "" && cyc(d[j], state)) return 1
  state[v] = 2
  return 0 }
BEGIN { mode = ENVIRON["RADIN_MODE"]; rankcsv = ENVIRON["RADIN_RANK"]
        infer = ENVIRON["RADIN_INFER"]; defer = ENVIRON["RADIN_DEFER"]; n = 0 }
$0 == "" { next }
{ n++; id[n] = jstr($0, "id"); title[n] = jstr($0, "title")
  prio[n] = jraw($0, "priority"); deps[n] = depscsv(jraw($0, "depends_on"))
  pos[id[n]] = n }
END {
  un = 0
  for (i = 1; i <= n; i++) if (prio[i] == "") unset[++un] = id[i]
  if (mode == "rank-needed") {
    for (k = 1; k <= un; k++) print unset[k]
    exit (un > 0 ? 0 : 1) }

  # --rank must name every unset id exactly once: a partial rank would drop
  # tasks from --steps, and a dropped task is a task that never runs.
  nr = 0
  if (rankcsv != "") {
    m = split(rankcsv, r, ",")
    for (j = 1; j <= m; j++) {
      v = r[j]; gsub(/[ \t]/, "", v)
      if (v == "") continue
      if (!(v in pos)) fail("--rank: no such task id: " v)
      if (prio[pos[v]] != "") fail("--rank: " v " already has a priority")
      if (v in rankpos) fail("--rank: duplicate id: " v)
      rankpos[v] = ++nr }
    if (nr != un) fail("--rank must name every unset-priority id exactly once: " un " expected, " nr " given") }

  # Effective deps: the index value wins per entry, --infer-deps only fills a
  # gap. The one place that precedence lives now.
  for (i = 1; i <= n; i++) eff[id[i]] = deps[i]
  if (infer != "") {
    m = split(infer, p, sprintf("%c", 31))
    for (j = 1; j <= m; j++) {
      if (p[j] == "") continue
      q = index(p[j], "=")
      if (q == 0) fail("--infer-deps needs <id>=<csv>, got: " p[j])
      a = substr(p[j], 1, q - 1); b = substr(p[j], q + 1)
      if (!(a in pos)) fail("--infer-deps: no such task id: " a)
      if (deps[pos[a]] != "") fail("--infer-deps: " a " already has depends_on in the index")
      nb = split(b, bb, ",")
      for (t = 1; t <= nb; t++) {
        if (bb[t] == "") continue
        if (!(bb[t] in pos)) fail("--infer-deps: no such task id: " bb[t])
        if (bb[t] == a) fail("--infer-deps: " a " cannot depend on itself") }
      eff[a] = b } }
  ndf = split(defer, df, ",")
  for (j = 1; j <= ndf; j++) {
    if (df[j] == "") continue
    if (!(df[j] in pos)) fail("--defer: no such task id: " df[j])
    isdef[df[j]] = 1 }
  # set-deps rejects a cycle, so only --infer-deps can introduce one -- and the
  # fix below only terminates on a DAG.
  for (i = 1; i <= n; i++) if (cyc(id[i], colour)) fail("--infer-deps would create a cycle through " id[i])

  for (i = 1; i <= n; i++) {
    if (prio[i] == "") { kc[i] = 1; kp[i] = 0; ks[i] = (nr > 0 ? rankpos[id[i]] : i) }
    else { kc[i] = 0; kp[i] = -(prio[i] + 0); ks[i] = i } }
  # ponytail: insertion sort -- no asort on BWK awk, and a backlog is the same
  # size prune_dep/deps_reaches already accept as O(n^2). Revisit only if a
  # real backlog ever makes `order` measurably slow.
  for (i = 1; i <= n; i++) {
    L[i] = i
    for (j = i; j > 1 && less(L[j], L[j - 1]); j--) { t = L[j]; L[j] = L[j - 1]; L[j - 1] = t } }
  for (k = 1; k <= n; k++) at[id[L[k]]] = k

  # The violated edges are a property of the priority order and the dep graph,
  # recorded before anything moves, so --report can never drift from the fix.
  nv = 0
  for (k = 1; k <= n; k++) {
    m = split(eff[id[L[k]]], d, ",")
    for (j = 1; j <= m; j++)
      if (d[j] != "" && at[d[j]] > k) { vdep[++nv] = d[j]; vent[nv] = id[L[k]] } }

  # The fix: move a dependency UP to immediately before its dependent and
  # leave every other relative position alone. Never Kahn with a priority
  # tie-break -- that satisfies an edge by demoting the dependent as readily
  # as by promoting the dep, reordering entries with no dependency relation at
  # all and discarding more of the human ranking than one override may.
  k = 1
  while (k <= n) {
    m = split(eff[id[L[k]]], d, ",")
    nd = 0
    for (j = 1; j <= m; j++) if (d[j] != "" && at[d[j]] > k) D[++nd] = at[d[j]]
    if (nd == 0) { k++; continue }
    for (a = 2; a <= nd; a++)
      for (b = a; b > 1 && D[b] < D[b - 1]; b--) { t = D[b]; D[b] = D[b - 1]; D[b - 1] = t }
    delete moved
    for (a = 1; a <= nd; a++) moved[D[a]] = 1
    nn = 0
    for (b = 1; b <= n; b++) {
      if (b in moved) continue
      if (b == k) for (a = 1; a <= nd; a++) NL[++nn] = L[D[a]]
      NL[++nn] = L[b] }
    for (b = 1; b <= n; b++) { L[b] = NL[b]; at[id[NL[b]]] = b }
    # k does not advance: the deps just pulled up are examined next, so their
    # own deps get pulled up too. Terminates because the graph is a DAG and
    # each pass strictly shrinks the violated-edge set.
  }

  if (mode == "report") {
    for (k = 1; k <= n; k++) printf("%d. %s (id: %s)\n", k, title[L[k]], id[L[k]])
    for (v = 1; v <= nv; v++) {
      pe = prio[pos[vent[v]]]
      # Silent only when neither entry carries a human priority: then the move
      # overrode nothing a human decided.
      if (pe == "" && prio[pos[vdep[v]]] == "") continue
      printf("dependency override: %s moved above %s (priority %s)\n",
             vdep[v], vent[v], (pe == "" ? "unset" : pe)) }
    exit 0 }
  if (mode == "steps") {
    for (k = 1; k <= n; k++)
      printf("%s%s%d%s%s%s%s\n", id[L[k]], TAB, k, TAB, eff[id[L[k]]], TAB,
             (id[L[k]] in isdef ? "deferred" : "pending"))
    exit 0 }
  fail("unknown mode: " mode) }
'

# `duplicates`: one pass counting both keyed fields. It flags, it never guesses
# which copy to drop -- that stays the user's call.
# shellcheck disable=SC2016  # $0 is awk's record, not a shell expansion
AWK_DUP='
$0 == "" { next }
{ i = jstr($0, "id"); t = jstr($0, "title")
  if (++ic[i] == 1) iord[++ni] = i
  if (++tc[t] == 1) tord[++nt] = t
  tids[t] = (tids[t] == "" ? i : tids[t] "," i)
  iids[i] = (iids[i] == "" ? i : iids[i] "," i) }
END { hit = 0
  for (k = 1; k <= ni; k++) if (ic[iord[k]] > 1) {
    hit = 1; printf("id%s%s%s%s\n", TAB, iord[k], TAB, iids[iord[k]]) }
  for (k = 1; k <= nt; k++) if (tc[tord[k]] > 1) {
    hit = 1; printf("title%s%s%s%s\n", TAB, tord[k], TAB, tids[tord[k]]) }
  exit (hit ? 0 : 1) }
'

# TSV is the agent-facing output format, so a tab/CR/LF in a title corrupts
# every consumer's field split.
require_plain_title() {
	[ "$(printf '%s' "$1" | tr -d '\t\r\n')" = "$1" ] ||
		die "title must not contain a tab, carriage return or newline: $1"
}

slugify() {
	printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
}

# Space-separated task ids from a raw "depends_on" array; empty when unset.
deps_ids() {
	printf '%s' "$1" | tr -d '[]" ' | tr ',' ' '
}

# JSON array literal for the ids in "$@", or nothing when there are none: an
# empty depends_on and an absent one mean the same thing on the index line.
deps_array() {
	local out="" d
	for d in "$@"; do
		[ -z "$out" ] || out="$out,"
		out="$out\"$d\""
	done
	[ -z "$out" ] || printf '[%s]\n' "$out"
}

# "id<TAB>category<TAB>title<TAB>file<TAB>priority<TAB>depends-on-csv" for a
# stream of raw index lines, so `find` keeps its TSV contract while `matches`
# hands callers the line itself. The last two fields are empty when unset.
fmt_lines() {
	awk "$AWK_JSON"'$0 != "" { print row($0, TAB) }'
}

# Absolute path of the task file whose index-relative location is $1.
task_path() {
	printf '%s/%s\n' "${BACKLOG_INDEX%/*}" "$1"
}

# Absolute path of the task file the index line $1 points at.
entry_path() {
	task_path "$(json_get file "$1")"
}

# The plan-file convention, owned here because `add-plan` takes a path and
# `radin-plan` has to write the file before it can point at it. $2 is an
# optional sub-task slug for a split plan.
plan_path() {
	if [ -n "${2:-}" ]; then
		printf '%s/plans/%s-%s.md\n' "$NAMESPACE_DIR" "$1" "$2"
	else
		printf '%s/plans/%s.md\n' "$NAMESPACE_DIR" "$1"
	fi
}

# The epic a `file` field belongs to, or empty at the flat tasks/ level.
file_epic() {
	case "$1" in
	tasks/*/*)
		local rest="${1#tasks/}"
		printf '%s\n' "${rest%%/*}"
		;;
	esac
}

require_epic_id() {
	[ "$(slugify "$1")" = "$1" ] || die "epic id must be a slug (lowercase, dashes), got: $1"
	[ -d "$BACKLOG_TASKS_DIR/$1" ] || die "no such epic: $1"
}

# True when the index already carries id $1, at any epic depth. Task ids stay
# globally unique: depends_on, `radin state prepare` and the radin/<id> branch
# name all key off the bare id, never off the epic path.
id_taken() {
	grep -qF "\"id\":\"$1\"" "$BACKLOG_INDEX" 2>/dev/null
}

# The only definition of "this epic holds no child task": DESCRIPTION.md is
# the epic's own root context, not a child.
epic_is_empty() {
	[ -z "$(find "$BACKLOG_TASKS_DIR/$1" -maxdepth 1 -name '*.md' ! -name DESCRIPTION.md -print -quit 2>/dev/null)" ]
}

# Drop an epic directory once its last child task is gone, so `epics` never
# reports a husk left behind by `remove`.
prune_empty_epic() {
	local epic="$1"
	[ -n "$epic" ] && [ -d "$BACKLOG_TASKS_DIR/$epic" ] || return 0
	epic_is_empty "$epic" || return 0
	rm -f "$BACKLOG_TASKS_DIR/$epic/DESCRIPTION.md"
	rmdir "$BACKLOG_TASKS_DIR/$epic" 2>/dev/null || true
}

# One index line. An empty $5/$6 omits the key entirely, so every verb that
# rewrites a line keeps "unset" unset instead of defaulting it to a value.
compose_line() {
	local out
	out="$(printf '{"id":"%s","category":"%s","title":"%s","file":"%s"' \
		"$1" "$2" "$(json_escape "$3")" "$4")"
	[ -z "$5" ] || out="$out,\"priority\":$5"
	[ -z "$6" ] || out="$out,\"depends_on\":$6"
	printf '%s}\n' "$out"
}

# Index line $1 with key $2 set to $3 (empty $3 drops the key), printed back.
# Only place that unpacks a line into compose_line's six arguments.
line_set_field() {
	local line="$1" key="$2" value="$3" category title file prio deps
	category="$(json_get category "$line")"
	title="$(json_get title "$line")"
	file="$(json_get file "$line")"
	prio="$(json_get_raw priority "$line")"
	deps="$(json_get_raw depends_on "$line")"
	case "$key" in
	category) category="$value" ;;
	title) title="$value" ;;
	file) file="$value" ;;
	priority) prio="$value" ;;
	depends_on) deps="$value" ;;
	*) die "line_set_field: unknown key: $key" ;;
	esac
	compose_line "$(json_get id "$line")" "$category" "$title" "$file" "$prio" "$deps"
}

# Replace the index with $1 in one rename, so a caller that dies while it
# builds the new content leaves the old index untouched. The trap keeps that
# dead run from leaving `.tmp` debris in the consumer's backlog directory.
write_index() {
	trap 'rm -f "$BACKLOG_INDEX.tmp"' EXIT
	printf '%s' "$1" >"$BACKLOG_INDEX.tmp"
	mv "$BACKLOG_INDEX.tmp" "$BACKLOG_INDEX"
	trap - EXIT
}

# Rewrite one key of the index line for id $1: $2 names the key, $3 is its
# new value, and an empty $3 drops the key. A key the caller does not name is
# always kept, so no argument ever has to mean "leave this alone".
set_index_field() {
	local id="$1" key="$2" value="$3" line out=""
	while IFS= read -r line || [ -n "$line" ]; do
		[ -n "$line" ] || continue
		if [ "$(json_get id "$line")" = "$id" ]; then
			line="$(line_set_field "$line" "$key" "$value")"
		fi
		out="$out$line
"
	done <"$BACKLOG_INDEX"
	write_index "$out"
}

# Drop id $1 from every other entry's depends_on: a dangling reference stalls
# `radin state deps-check` exactly like a cycle does.
prune_dep() {
	local gone="$1" line raw dep kept out=""
	while IFS= read -r line || [ -n "$line" ]; do
		[ -n "$line" ] || continue
		raw="$(json_get_raw depends_on "$line")"
		case "$raw" in *"\"$gone\""*)
			kept=""
			for dep in $(deps_ids "$raw"); do
				[ "$dep" = "$gone" ] || kept="$kept $dep"
			done
			# shellcheck disable=SC2086
			line="$(line_set_field "$line" depends_on "$(deps_array $kept)")"
			;;
		esac
		out="$out$line
"
	done <"$BACKLOG_INDEX"
	write_index "$out"
}

remove_by_id() {
	local line rel="" kept
	line="$(grep -F "\"id\":\"$1\"" "$BACKLOG_INDEX" || true)"
	if [ -n "$line" ]; then
		rel="$(json_get file "$line")"
		rm -f "$(task_path "$rel")"
		prune_empty_epic "$(file_epic "$rel")"
	fi
	kept="$(grep -v -F "\"id\":\"$1\"" "$BACKLOG_INDEX" || true)"
	[ -z "$kept" ] || kept="$kept
"
	write_index "$kept"
	prune_dep "$1"
}

# Matching JSONL lines for query $1: exact id, else exact title, else
# case-insensitive substring on title.
matches() {
	RADIN_Q="$1" awk "$AWK_JSON$AWK_MATCH" "$BACKLOG_INDEX"
}

# The one matching raw index line for query $1, or die with what was found.
single_match() {
	local found n
	found="$(matches "$1")"
	[ -n "$found" ] || die "no entry matches: $1"
	n="$(printf '%s\n' "$found" | grep -c '.')"
	[ "$n" -eq 1 ] || die "matches $n entries: $1
$(printf '%s\n' "$found" | fmt_lines)"
	printf '%s\n' "$found"
}

# `plan<TAB><path>` / `skill<TAB><instruction>` / `acceptance<TAB><criterion>`
# lines from the task file $1. One parser, shared by `meta` and `field`: a
# second copy would drift the next time a label changes.
meta_lines() {
	local line in_acceptance="" crit
	while IFS= read -r line || [ -n "$line" ]; do
		if [ -n "$in_acceptance" ]; then
			case "$line" in
			'- '*)
				crit="${line#- }"
				case "$crit" in
				'[ ] '* | '[x] '* | '[X] '*)
					crit="${crit#????}"
					;;
				esac
				printf 'acceptance\t%s\n' "$crit"
				continue
				;;
			*) in_acceptance="" ;;
			esac
		fi
		case "$line" in
		'**Plan:** '*) printf 'plan\t%s\n' "${line#"**Plan:** "}" ;;
		'**Skill:** '*) printf 'skill\t%s\n' "${line#"**Skill:** "}" ;;
		'**Acceptance:**') in_acceptance=1 ;;
		esac
	done <"$1"
}

# Skills an execution sub-agent cannot run: it has no user to ask, no
# sub-agent of its own, no `Workflow` tool, and a radin entry point would
# recurse (docs/technical-constraints.md has the why for each).
# Written with the leading slash a user would type, so tests/skill-names.bats
# pins each one to a skill radin or a companion actually ships.
SKILL_DENY="/mattpocock-skills:grilling /mattpocock-skills:research /deep-research /radin-execute /radin-plan /radin-review"

# The leading `/<name>` token of a `**Skill:**` instruction, empty when it has
# none.
skill_token() {
	case "$1" in
	*/*) ;;
	*) return 0 ;;
	esac
	printf '%s' "${1#*/}" | sed -E 's|[^a-z0-9:_-].*$||'
}

# True when instruction $1 names a denied skill. Matched on that token alone,
# never on the surrounding prose: an instruction with no `/<name>` is a
# standing user instruction and is forwarded untouched, never judged on fit.
skill_denied() {
	local name
	name="$(skill_token "$1")"
	[ -n "$name" ] || return 1
	case " $SKILL_DENY " in *" /$name "*) return 0 ;; esac
	# The one class that needs a filesystem check: any saved workflow command.
	[ ! -f "$REPO_ROOT/.claude/workflows/$name.md" ] || return 0
	[ ! -f "$HOME/.claude/workflows/$name.md" ] || return 0
	return 1
}

require_integer() {
	case "$1" in
	'' | - | *[!0-9-]* | ?*-*) die "priority must be an integer, got: $1" ;;
	esac
}

# Fibonacci sizing scale, ascending with radin's "higher wins", so 21 is the
# most important. Seven candidates is a smaller decision for an agent than an
# unbounded integer. Enforced on write only: index lines written before the
# scale existed keep loading, listing and rendering, and no verb rewrites them.
PRIORITY_SCALE="1 2 3 5 8 13 21"

require_priority() {
	case " $PRIORITY_SCALE " in
	*" $1 "*) ;;
	*) die "priority must be one of $PRIORITY_SCALE (higher wins), got: $1" ;;
	esac
}

# Every id in "$@" must already exist. A missing index just has no known ids,
# so `add`'s first task still reports the unknown id rather than the index.
require_known_ids() {
	local d
	for d in "$@"; do
		grep -qF "\"id\":\"$d\"" "$BACKLOG_INDEX" 2>/dev/null ||
			die "no such task id: $d"
	done
}

# True when target $1 is reachable from the ids in "$@". The seen list is what
# stops a graph that already has a cycle from looping forever.
deps_reaches() {
	local target="$1" pending frontier seen="" cur line
	shift
	pending="$*"
	while [ -n "$pending" ]; do
		frontier="$pending"
		pending=""
		for cur in $frontier; do
			[ "$cur" != "$target" ] || return 0
			case " $seen " in *" $cur "*) continue ;; esac
			seen="$seen $cur"
			line="$(grep -F "\"id\":\"$cur\"" "$BACKLOG_INDEX" || true)"
			[ -n "$line" ] || continue
			pending="$pending $(deps_ids "$(json_get_raw depends_on "$line")")"
		done
	done
	return 1
}

cmd="${1:-}"
case "$cmd" in
help)
	if [ -n "${2:-}" ]; then
		out="$(usage_for "$2")"
		[ -n "$out" ] || die "unknown command: $2
$(usage_lines)"
		printf '%s\n' "$out"
	else
		usage_lines
	fi
	;;

env)
	case "${2:-}" in
	'' | --export) ;;
	*) usage_die env "env takes only --export, got: $2" ;;
	esac
	[ $# -le 2 ] || usage_die env "env takes at most one argument, got: $3"
	if [ "${2:-}" = "--export" ]; then
		bash "$LIB_DIR/radin-namespace.sh" | sed 's/^/export /'
	else
		bash "$LIB_DIR/radin-namespace.sh"
	fi
	;;

show)
	require_index
	[ -z "${2:-}" ] || case "$2" in
	feat | fix | chore | refactor) ;;
	*) usage_die show "category must be feat|fix|chore|refactor, got: $2" ;;
	esac
	[ $# -le 2 ] || usage_die show "show takes at most one category, got: $3"
	printf '# Backlog\n'
	cats="feat fix chore refactor"
	[ -z "${2:-}" ] || cats="$2"
	# One awk pass for every field `show` needs, so the markdown below costs
	# one `cat` per task body and no fork per field.
	rows="$(awk "$AWK_JSON"'$0 != "" { print jstr($0, "category") US fepic(jstr($0, "file")) US jstr($0, "title") US jstr($0, "file") }' "$BACKLOG_INDEX")"
	for cat in $cats; do
		# One pass in `file` order: flat tasks first, then each epic's
		# children below its shared context, so a human reading `show`
		# sees the hierarchy the `file` paths encode.
		section="$(printf '%s\n' "$rows" | awk -F"$US" -v c="$cat" '$1 == c' | sort -s -t"$US" -k2,2)"
		[ -n "$section" ] || continue
		printf '\n## %s\n' "$cat"
		cur=""
		while IFS="$US" read -r rcat epic title file; do
			[ -n "$rcat" ] || continue
			if [ "$epic" != "$cur" ]; then
				cur="$epic"
				printf '\n### epic: %s\n' "$epic"
				[ ! -s "$BACKLOG_TASKS_DIR/$epic/DESCRIPTION.md" ] ||
					cat "$BACKLOG_TASKS_DIR/$epic/DESCRIPTION.md"
			fi
			if [ -z "$epic" ]; then level='###'; else level='####'; fi
			printf '\n%s %s\n' "$level" "$title"
			cat "$(task_path "$file")"
		done <<-SECTION
			$section
		SECTION
	done
	;;

list)
	require_index
	shift
	RADIN_CAT=""
	RADIN_EPIC=""
	RADIN_PMIN=""
	RADIN_PMAX=""
	RADIN_JSON=""
	RADIN_PLANNED=""
	RADIN_DIR="${BACKLOG_INDEX%/*}"
	order=priority
	while [ $# -gt 0 ]; do
		case "$1" in
		--category)
			case "${2:-}" in
			feat | fix | chore | refactor) RADIN_CAT="$2" ;;
			*) usage_die list "--category must be feat|fix|chore|refactor, got: ${2:-<none>}" ;;
			esac
			shift 2
			;;
		--priority-min)
			[ -n "${2:-}" ] || usage_die list "--priority-min needs an integer"
			require_integer "$2"
			RADIN_PMIN="$2"
			shift 2
			;;
		--priority-max)
			[ -n "${2:-}" ] || usage_die list "--priority-max needs an integer"
			require_integer "$2"
			RADIN_PMAX="$2"
			shift 2
			;;
		--epic)
			[ -n "${2:-}" ] || usage_die list "--epic needs an epic id"
			require_epic_id "$2"
			RADIN_EPIC="$2"
			shift 2
			;;
		--order)
			case "${2:-}" in
			created | priority) order="$2" ;;
			*) usage_die list "--order must be created|priority, got: ${2:-<none>}" ;;
			esac
			shift 2
			;;
		--planned)
			RADIN_PLANNED=1
			shift
			;;
		--json)
			RADIN_JSON=1
			shift
			;;
		*) usage_die list "unknown list option: $1" ;;
		esac
	done
	# Priority descending with unset last is the ordering contract, not a
	# display choice: a consumer reads this order as the human's ranking.
	# -s keeps equal priorities in index order, and the rank class in field 1
	# is what puts every unset priority after every set one.
	# --order created is index order, which is creation order because
	# index.jsonl is append-only: the TUI wants a list no mutation reorders.
	export RADIN_CAT RADIN_EPIC RADIN_PMIN RADIN_PMAX RADIN_JSON RADIN_PLANNED RADIN_DIR
	if [ "$order" = created ]; then
		awk "$AWK_JSON$AWK_LIST" "$BACKLOG_INDEX" | cut -f3-
	else
		awk "$AWK_JSON$AWK_LIST" "$BACKLOG_INDEX" |
			sort -s -t"$TAB" -k1,1n -k2,2nr | cut -f3-
	fi
	;;

find)
	[ -n "${2:-}" ] || usage_die find "find needs an id or title"
	require_index
	out="$(matches "$2" | fmt_lines)"
	[ -n "$out" ] || die "no entry matches: $2"
	printf '%s\n' "$out"
	;;

add)
	category="${2:-}"
	title="${3:-}"
	[ -n "$title" ] || usage_die add "add needs a category and a title, with the body on stdin"
	case "$category" in
	feat | fix | chore | refactor) ;;
	*) usage_die add "category must be feat|fix|chore|refactor, got: $category" ;;
	esac
	shift 3
	skills=""
	epic=""
	priority=""
	deps=""
	while [ $# -gt 0 ]; do
		case "$1" in
		--priority)
			[ -n "${2:-}" ] || usage_die add "--priority needs one of $PRIORITY_SCALE"
			require_priority "$2"
			priority="$2"
			shift 2
			;;
		--depends-on)
			[ -n "${2:-}" ] || usage_die add "--depends-on needs a csv of task ids"
			deps="$(printf '%s' "$2" | tr ',' ' ')"
			# Checked before the task file is written, so a bad flag
			# leaves no orphan body behind.
			# shellcheck disable=SC2086
			require_known_ids $deps
			shift 2
			;;
		--skill)
			[ -n "${2:-}" ] || usage_die add "--skill needs a name"
			skills="$skills$2
"
			shift 2
			;;
		--epic)
			[ -n "${2:-}" ] || usage_die add "--epic needs an epic id"
			epic="$2"
			require_epic_id "$epic"
			shift 2
			;;
		*) usage_die add "unknown add option: $1" ;;
		esac
	done
	require_plain_title "$title"
	BODY="$(cat)"
	[ -n "$BODY" ] || die "entry body is empty (pass it on stdin)"
	id="$(slugify "$title")"
	[ -n "$id" ] || die "title produced an empty id: $title"
	base="$id"
	n=2
	while id_taken "$id"; do
		id="$base-$n"
		n=$((n + 1))
	done
	# `add` is the one verb that decides a task's location instead of reading
	# it: the `file` field it writes here is what lets every other verb read.
	if [ -n "$epic" ]; then
		rel="tasks/$epic/$id.md"
	else
		rel="tasks/$id.md"
	fi
	task_file="$(task_path "$rel")"
	printf '%s\n' "$BODY" >"$task_file"
	printf '%s' "$skills" | while IFS= read -r s; do
		[ -n "$s" ] || continue
		printf '**Skill:** Invoke %s to tackle this task.\n' "$s" >>"$task_file"
	done
	# shellcheck disable=SC2086
	dep_array="$(deps_array $deps)"
	compose_line "$id" "$category" "$title" "$rel" "$priority" "$dep_array" >>"$BACKLOG_INDEX"
	printf 'added "%s" (id: %s) under %s in %s\n' "$title" "$id" "$category" "$BACKLOG_INDEX"
	;;

count)
	[ $# -le 1 ] || usage_die count "count takes no argument, got: $2"
	if [ -s "$BACKLOG_INDEX" ]; then
		grep -c . "$BACKLOG_INDEX" || true
	else
		printf '0\n'
	fi
	;;

meta)
	[ -n "${2:-}" ] || usage_die meta "meta needs an id or title"
	require_index
	entry="$(single_match "$2")"
	meta_lines "$(entry_path "$entry")"
	;;

order)
	require_index
	shift
	RADIN_MODE=""
	RADIN_RANK=""
	RADIN_INFER=""
	RADIN_DEFER=""
	while [ $# -gt 0 ]; do
		case "$1" in
		--rank-needed | --report | --steps)
			[ -z "$RADIN_MODE" ] ||
				usage_die order "order takes exactly one mode, got --$RADIN_MODE and $1"
			RADIN_MODE="${1#--}"
			shift
			;;
		--rank)
			[ -n "${2:-}" ] || usage_die order "--rank needs a csv of task ids"
			RADIN_RANK="$2"
			shift 2
			;;
		--infer-deps)
			[ -n "${2:-}" ] || usage_die order "--infer-deps needs <id>=<csv>"
			RADIN_INFER="$RADIN_INFER$2$US"
			shift 2
			;;
		--defer)
			[ -n "${2:-}" ] || usage_die order "--defer needs a csv of task ids"
			RADIN_DEFER="$2"
			shift 2
			;;
		*) usage_die order "unknown order option: $1" ;;
		esac
	done
	# No default mode: a default that exits 1 on the healthy path (--rank-needed
	# does) is a trap for a caller routing on exit codes.
	[ -n "$RADIN_MODE" ] ||
		usage_die order "order needs one of --rank-needed, --report, --steps"
	export RADIN_MODE RADIN_RANK RADIN_INFER RADIN_DEFER
	awk "$AWK_JSON$AWK_ORDER" "$BACKLOG_INDEX"
	;;

field)
	query="${2:-}"
	fname="${3:-}"
	[ -n "$fname" ] || usage_die field "field needs an id or title and a placeholder name"
	require_index
	# One call per placeholder, each printing that value and nothing else: a
	# `NAME<TAB>value` listing would put the caller back to picking a line out
	# of output. The resolve dies on zero or several matches, so this call's
	# exit code IS the existence check -- no separate `find` needed.
	entry="$(single_match "$query")"
	case "$fname" in
	TASK_ID) printf '%s\n' "$(json_get id "$entry")" ;;
	CATEGORY) printf '%s\n' "$(json_get category "$entry")" ;;
	TASK_FILE) entry_path "$entry" ;;
	PLAN_PATHS | SKILLS | SKILLS_DROPPED | ACCEPTANCE)
		meta="$(meta_lines "$(entry_path "$entry")")"
		plans=""
		kept=""
		dropped=""
		crits=""
		while IFS= read -r line || [ -n "$line" ]; do
			case "$line" in
			"plan$TAB"*)
				[ -z "$plans" ] || plans="$plans, "
				plans="$plans${line#plan"$TAB"}"
				;;
			"skill$TAB"*)
				inst="${line#skill"$TAB"}"
				if skill_denied "$inst"; then
					dropped="$dropped$inst
"
				else
					kept="$kept$inst
"
				fi
				;;
			"acceptance$TAB"*)
				crits="$crits   - ${line#acceptance"$TAB"}
"
				;;
			esac
		done <<-META
			$meta
		META
		case "$fname" in
		PLAN_PATHS)
			[ -n "$plans" ] || {
				printf 'none — implement directly from the entry\n'
				exit 1
			}
			printf '%s\n' "$plans"
			;;
		SKILLS)
			if [ -n "$kept" ]; then printf '%s' "$kept"; else printf 'none\n'; fi
			;;
		SKILLS_DROPPED)
			[ -n "$dropped" ] || exit 1
			printf '%s' "$dropped"
			;;
		ACCEPTANCE)
			# Exit 1 with no output is the caller's "delete the whole
			# ACCEPTANCE line" signal. Never synthesise a criterion.
			[ -n "$crits" ] || exit 1
			printf '1b. This task states its own acceptance criteria. They are the bar it is\n'
			printf '   measured against, so satisfy every one of them:\n'
			printf '%s' "$crits"
			;;
		esac
		;;
	*) usage_die field "unknown field name: $fname" ;;
	esac
	;;

duplicates)
	require_index
	[ $# -le 1 ] || usage_die duplicates "duplicates takes no argument, got: $2"
	awk "$AWK_JSON$AWK_DUP" "$BACKLOG_INDEX"
	;;

planned)
	require_index
	[ $# -le 1 ] || usage_die planned "planned takes no argument, got: $2"
	RADIN_DIR="${BACKLOG_INDEX%/*}" awk "$AWK_JSON$AWK_PLANNED" "$BACKLOG_INDEX"
	;;

append)
	[ -n "${2:-}" ] || usage_die append "append needs an id or title, with the text on stdin"
	require_index
	entry="$(single_match "$2")"
	BODY="$(cat)"
	[ -n "$BODY" ] || die "append text is empty (pass it on stdin)"
	printf '\n%s\n' "$BODY" >>"$(entry_path "$entry")"
	printf 'appended to "%s"\n' "$(json_get title "$entry")"
	;;

add-plan)
	query="${2:-}"
	plan_path="${3:-}"
	[ -n "$plan_path" ] || usage_die add-plan "add-plan needs an id or title and a plan path"
	require_index
	entry="$(single_match "$query")"
	printf '**Plan:** %s\n' "$plan_path" >>"$(entry_path "$entry")"
	printf 'plan pointer added to "%s"\n' "$(json_get title "$entry")"
	;;

path)
	[ -n "${2:-}" ] || usage_die path "path needs an id or title"
	require_index
	entry="$(single_match "$2")"
	entry_path "$entry"
	;;

plan-target)
	[ -n "${2:-}" ] || usage_die plan-target "plan-target needs an id or title"
	[ $# -le 3 ] || usage_die plan-target "plan-target takes an id or title and at most one sub-slug, got: $4"
	require_index
	# `single_match` dies the same way on zero and on several, so the four
	# routes are resolved here instead of by a caller counting `find` lines.
	found="$(matches "$2")"
	if [ -z "$found" ]; then
		printf 'radin-backlog: no entry matches: %s\n' "$2" >&2
		exit 1
	fi
	if [ "$(printf '%s\n' "$found" | grep -c '.')" -ne 1 ]; then
		printf 'radin-backlog: "%s" matches several entries:\n' "$2" >&2
		printf '%s\n' "$found" | fmt_lines | sed 's/^/candidate\t/' >&2
		exit 2
	fi
	tid="$(json_get id "$found")"
	printf 'id\t%s\ntitle\t%s\ntask_file\t%s\nplan_file\t%s\n' \
		"$tid" "$(json_get title "$found")" \
		"$(entry_path "$found")" "$(plan_path "$tid" "${3:-}")"
	plans="$(meta_lines "$(entry_path "$found")" | grep "^plan$TAB" || true)"
	[ -z "$plans" ] || {
		printf '%s\n' "$plans"
		exit 3
	}
	;;

set-category)
	query="${2:-}"
	newcat="${3:-}"
	[ -n "$newcat" ] || usage_die set-category "set-category needs an id or title and a category"
	case "$newcat" in
	feat | fix | chore | refactor) ;;
	*) usage_die set-category "category must be feat|fix|chore|refactor, got: $newcat" ;;
	esac
	require_index
	entry="$(single_match "$query")"
	id="$(json_get id "$entry")"
	set_index_field "$id" category "$newcat"
	printf 'moved "%s" to %s\n' "$(json_get title "$entry")" "$newcat"
	;;

retitle)
	query="${2:-}"
	newtitle="${3:-}"
	[ -n "$newtitle" ] || usage_die retitle "retitle needs an id or title and a new title"
	require_plain_title "$newtitle"
	require_index
	entry="$(single_match "$query")"
	id="$(json_get id "$entry")"
	set_index_field "$id" title "$newtitle"
	printf 'retitled %s to "%s"\n' "$id" "$newtitle"
	;;

set-priority)
	query="${2:-}"
	value="${3:-}"
	[ -n "$value" ] || usage_die set-priority "set-priority needs an id or title and one of $PRIORITY_SCALE or --none"
	[ "$value" = "--none" ] || require_priority "$value"
	require_index
	entry="$(single_match "$query")"
	id="$(json_get id "$entry")"
	newprio="$value"
	[ "$value" != "--none" ] || newprio=""
	set_index_field "$id" priority "$newprio"
	printf 'priority of %s set to %s\n' "$id" "$value"
	;;

set-deps)
	query="${2:-}"
	value="${3:-}"
	[ -n "$value" ] || usage_die set-deps "set-deps needs an id or title and a csv of ids or --none"
	require_index
	entry="$(single_match "$query")"
	id="$(json_get id "$entry")"
	if [ "$value" = "--none" ]; then
		dep_array=""
	else
		deps="$(printf '%s' "$value" | tr ',' ' ')"
		# Validation lives here, not in a skill: an unknown id or a cycle
		# makes `radin state deps-check` wait forever instead of failing.
		# shellcheck disable=SC2086
		require_known_ids $deps
		# shellcheck disable=SC2086
		deps_reaches "$id" $deps &&
			die "depends_on would create a cycle through $id"
		# shellcheck disable=SC2086
		dep_array="$(deps_array $deps)"
	fi
	set_index_field "$id" depends_on "$dep_array"
	printf 'depends_on of %s set to %s\n' "$id" "$value"
	;;

remove)
	query="${2:-}"
	[ -n "$query" ] || usage_die remove "remove needs an id or title"
	require_index
	entry="$(single_match "$query")"
	id="$(json_get id "$entry")"
	title="$(json_get title "$entry")"
	remove_by_id "$id"
	printf 'removed "%s" (id: %s)\n' "$title" "$id"
	;;

reconcile)
	# A task's success is recorded in completed.json (radin-state.sh
	# completed-add) BEFORE its backlog entry is removed. If the run dies
	# between those two steps the completed entry stays in the backlog and
	# looks unstarted next session. Reconcile closes that gap: drop every
	# backlog entry whose id already sits in completed.json.
	# ponytail: id-keyed match. A brand-new task that reuses a removed
	# task's slug (same title) would be dropped too; clear completed.json
	# between sessions if that ever bites.
	completed_file="${2:-}"
	[ -n "$completed_file" ] || usage_die reconcile "reconcile needs a completed-file path"
	require_index
	[ -f "$completed_file" ] || {
		printf 'reconcile: no completed file, nothing to do\n'
		exit 0
	}
	removed=""
	while IFS= read -r cline || [ -n "$cline" ]; do
		[ -n "$cline" ] || continue
		cid="$(json_get id "$cline")"
		[ -n "$cid" ] || continue
		if grep -qF "\"id\":\"$cid\"" "$BACKLOG_INDEX"; then
			remove_by_id "$cid"
			removed="$removed $cid"
		fi
	done <"$completed_file"
	[ -n "$removed" ] && printf 'reconcile: dropped already-completed entries:%s\n' "$removed" || printf 'reconcile: no stale completed entries\n'
	;;

epics)
	[ $# -le 1 ] || usage_die epics "epics takes no argument, got: $2"
	# A directory listing is the whole store: an epic index file would be a
	# second copy of what one `ls` already knows.
	for d in "$BACKLOG_TASKS_DIR"/*/; do
		[ -d "$d" ] || continue
		d="${d%/}"
		printf '%s\n' "${d##*/}"
	done
	;;

epic-add)
	epic="${2:-}"
	[ -n "$epic" ] || usage_die epic-add "epic-add needs an epic id, with the description on stdin"
	[ "$(slugify "$epic")" = "$epic" ] || die "epic id must be a slug (lowercase, dashes), got: $epic"
	[ ! -d "$BACKLOG_TASKS_DIR/$epic" ] || die "epic already exists: $epic"
	id_taken "$epic" && die "a task already uses that id: $epic"
	mkdir -p "$BACKLOG_TASKS_DIR/$epic"
	if [ -t 0 ]; then
		: >"$BACKLOG_TASKS_DIR/$epic/DESCRIPTION.md"
	else
		cat >"$BACKLOG_TASKS_DIR/$epic/DESCRIPTION.md"
	fi
	printf 'created epic %s\n' "$epic"
	;;

epic-show)
	epic="${2:-}"
	[ -n "$epic" ] || usage_die epic-show "epic-show needs an epic id"
	require_epic_id "$epic"
	[ ! -s "$BACKLOG_TASKS_DIR/$epic/DESCRIPTION.md" ] ||
		cat "$BACKLOG_TASKS_DIR/$epic/DESCRIPTION.md"
	;;

epic-move)
	query="${2:-}"
	target="${3:-}"
	[ -n "$target" ] || usage_die epic-move "epic-move needs an id or title and an epic id or --none"
	require_index
	entry="$(single_match "$query")"
	id="$(json_get id "$entry")"
	old_rel="$(json_get file "$entry")"
	if [ "$target" = "--none" ]; then
		new_rel="tasks/$id.md"
	else
		require_epic_id "$target"
		new_rel="tasks/$target/$id.md"
	fi
	[ "$old_rel" != "$new_rel" ] || die "already there: $old_rel"
	mv "$(task_path "$old_rel")" "$(task_path "$new_rel")"
	set_index_field "$id" file "$new_rel"
	prune_empty_epic "$(file_epic "$old_rel")"
	printf 'moved %s to %s\n' "$id" "$new_rel"
	;;

epic-remove)
	epic="${2:-}"
	[ -n "$epic" ] || usage_die epic-remove "epic-remove needs an epic id"
	require_epic_id "$epic"
	# Never recursively delete tasks: the operator moves them out first.
	epic_is_empty "$epic" ||
		die "epic $epic still holds child tasks; epic-move them out first"
	rm -f "$BACKLOG_TASKS_DIR/$epic/DESCRIPTION.md"
	rmdir "$BACKLOG_TASKS_DIR/$epic"
	printf 'removed epic %s\n' "$epic"
	;;

*)
	# No hand-maintained command list here: the header comment block is it.
	die "unknown command: ${cmd:-<none>}
$(usage_lines)"
	;;
esac
