#!/usr/bin/env bash
# Deterministic backlog operations, so agents/skills don't hand-edit backlog
# storage. Installed to ~/.claude/.radin/lib/radin-backlog.sh by install.sh.
#
# Storage: $BACKLOG_INDEX is a JSONL file (one compact JSON object per line,
# one per task: {"id":...,"category":...,"title":...,"file":...}), plus the
# optional "priority":<1|2|3|5|8|13|21> and "depends_on":[<id>,...] keys a human
# sets.
# Each line's `file` field, relative to the backlog directory, is the
# authoritative location of that task's prose body: `add` decides it, every
# other verb reads it back. Splitting each task into its own file means
# appending to one task can never shift another task's content — unlike the
# old single-file BACKLOG.md, nothing here is ever addressed by line number.
#
# Five per-task fields a parser reads are JSON keys on the index line rather
# than markdown labels in the body: "plan", "skills" and "acceptance" (arrays
# of strings), "facts" and "location" (strings). `add --skill`, `add-plan` and
# `set-meta` write them, `meta` reads them, and `add`/`append` reject a body
# line that repeats one, so a malformed value fails loudly on write instead of
# silently yielding nothing on read.
#
# Usage:
#   radin-backlog.sh help [command]              # print every command's usage, or one command's
#   radin-backlog.sh env [--export]             # print REPO_ROOT/NAMESPACE_DIR/BACKLOG_INDEX/BACKLOG_TASKS_DIR (--export: source-able with export)
#   radin-backlog.sh show [category]             # print backlog as markdown, or one ## section
#   radin-backlog.sh list [--order created|priority] [--planned]  # print "id<US>category<US>title<US>file<US>priority<US>depends-on-csv" (US = \037), priority-descending by default, unset priorities last (--order created gives index order; --planned appends a 7th P/empty field)
#   radin-backlog.sh find <id-or-title>          # print matching "id<TAB>category<TAB>title<TAB>file<TAB>priority<TAB>depends-on-csv" line(s)
#   radin-backlog.sh count                       # print the number of entries (0 without an index)
#   radin-backlog.sh add <category> <title> [--skill <name>]...  # create task, body read from stdin, prints its id
#   radin-backlog.sh add-plan <id-or-title> <path>  # add one plan pointer to the task's entry
#   radin-backlog.sh append <id-or-title>        # append text from stdin to the task's file
#   radin-backlog.sh plan-target <id-or-title> [<sub-slug>]  # resolve one task for planning: "id"/"title"/"task_file"/"plan_file" TAB lines plus a "facts<TAB><path>" line when set and one "plan<TAB><path>" per existing pointer; exit 1 no match, 2 several (candidates on stderr), 3 already planned
#   radin-backlog.sh set-category <id-or-title> <category>  # move a task to another category
#   radin-backlog.sh retitle <id-or-title> <title>  # change a task's title (its id never changes)
#   radin-backlog.sh set-priority <id-or-title> <1|2|3|5|8|13|21|--none>  # set/clear the priority (higher wins)
#   radin-backlog.sh set-deps <id-or-title> <csv-of-ids|--none>   # set/clear depends_on (rejects an unknown id and any cycle)
#   radin-backlog.sh set-meta <id-or-title> <plan|skills|acceptance|facts|location> <value>...|--none  # set/clear one index-line field (skills takes skill names; facts and location take exactly one value)
#   radin-backlog.sh meta <id-or-title>          # print "plan<TAB><path>" / "skill<TAB><instruction>" / "acceptance<TAB><criterion>" / "facts<TAB><path>" / "location<TAB><path:line>" lines from the task's entry
#   radin-backlog.sh order <--rank-needed|--report|--steps> [--rank <csv-of-ids>] [--infer-deps <id>=<csv>]... [--defer <csv-of-ids>]  # the execution order: the priority order with the topological dependency fix applied (--rank-needed: print every unset-priority id, exit 1 when there are none; --report: "<order>. <title> (id: <id>)" plus one "dependency override:" line per violated edge; --steps: "id<TAB>order<TAB>depends-on-csv<TAB>pending|deferred", which is `radin state steps-init`'s stdin format)
#   radin-backlog.sh field <id-or-title> <TASK_FILE|TASK_BODY|EPIC_CONTEXT|TASK_ID|CATEGORY|PLAN_PATHS|SKILLS|SKILLS_DROPPED|ACCEPTANCE|FACTS|LOCATION>  # one Execution-prompt placeholder, rendered ready to substitute
#   radin-backlog.sh duplicates                  # print "id<TAB><value><TAB><ids>" / "title<TAB><value><TAB><ids>" per duplicated value, exit 1 when there are none
#   radin-backlog.sh remove <id-or-title>        # delete task file + index entry (exact single match required)
#   radin-backlog.sh reconcile                  # drop backlog entries whose id is already in completed.json
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
# shellcheck disable=SC2016  # the $ are awk regex anchors, not shell expansions
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
# jarr/jhas/jspan/jsplice are awk-only and have no radin-json.sh twin on
# purpose: shell composes a JSON array (json_array) and awk parses one, because
# an element of prose can hold a space, a comma, a `]` and a quote -- which the
# `[^]]*` regex in json_get_raw and the gsub in depscsv both corrupt. jarr
# fills out[1..n] with the array at key, by the same character walk jstr uses.
function jarr(line, key, out,   s, n, i, c, cnt, cur, inq) {
  cnt = 0
  if (match(line, "\"" key "\":\\[") == 0) return 0
  s = substr(line, RSTART + RLENGTH); n = length(s); cur = ""; inq = 0
  for (i = 1; i <= n; i++) { c = substr(s, i, 1)
    if (inq) {
      if (c == "\\") { i++; cur = cur substr(s, i, 1); continue }
      if (c == "\"") { out[++cnt] = cur; cur = ""; inq = 0; continue }
      cur = cur c; continue }
    if (c == "\"") { inq = 1; continue }
    if (c == "]") break }
  return cnt }
function jhas(line, key) { return match(line, "\"" key "\":") > 0 }
# The span of `"key":<value>` in line, as JSP_AT/JSP_LEN; 0 when key is absent.
function jspan(line, key,   s, n, i, c, inq) {
  if (match(line, "\"" key "\":") == 0) return 0
  JSP_AT = RSTART; JSP_LEN = RLENGTH
  s = substr(line, RSTART + RLENGTH); n = length(s); c = substr(s, 1, 1)
  if (c == "\"") {
    for (i = 2; i <= n; i++) { c = substr(s, i, 1)
      if (c == "\\") { i++; continue }
      if (c == "\"") { JSP_LEN += i; return 1 } }
    return 0 }
  if (c == "[") {
    for (i = 2; i <= n; i++) { c = substr(s, i, 1)
      if (inq) { if (c == "\\") i++; else if (c == "\"") inq = 0; continue }
      if (c == "\"") { inq = 1; continue }
      if (c == "]") { JSP_LEN += i; return 1 } }
    return 0 }
  if (match(s, /^-?[0-9]+/) == 0) return 0
  JSP_LEN += RLENGTH
  return 1 }
# line with key set to the pre-escaped raw JSON value, or with key dropped when
# raw is empty. It splices over the existing value instead of rebuilding the
# line from parsed pieces, so an already-escaped title is never escaped twice;
# a key the line does not carry yet lands before the closing brace.
function jsplice(line, key, raw,   pre, post) {
  if (jspan(line, key)) {
    pre = substr(line, 1, JSP_AT - 1); post = substr(line, JSP_AT + JSP_LEN)
    if (raw == "") { sub(/,$/, "", pre); return pre post }
    return pre "\"" key "\":" raw post }
  if (raw == "") return line
  sub(/}[ \t]*$/, "", line)
  return line ",\"" key "\":" raw "}" }
function depscsv(raw,   t) { t = raw; gsub(/[][" ]/, "", t); return t }
function fepic(f,   r) { if (f !~ /^tasks\/[^\/]+\//) return ""
                         r = substr(f, 7); sub(/\/.*$/, "", r); return r }
function row(line, sep) {
  return jstr(line, "id") sep jstr(line, "category") sep jstr(line, "title") \
         sep jstr(line, "file") sep jraw(line, "priority") \
         sep depscsv(jraw(line, "depends_on")) }
'

# `list`: the row and its sort keys in one pass. The two leading keys are TAB-separated
# from the row because require_plain_title already rejects a tab in a title,
# so `cut -f3-` can never split a row.
# shellcheck disable=SC2016  # $0 is awk's record, not a shell expansion
AWK_LIST='
BEGIN { plan = ENVIRON["RADIN_PLANNED"] }
$0 == "" { next }
{ p = jraw($0, "priority")
  out = row($0, US)
  if (plan != "") out = out US (jhas($0, "plan") ? "P" : "")
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

# `meta`: the five parser-read fields of one index line on stdin, in a fixed
# key order. One parser, shared by `meta`, `field`, `plan-target` and `show`:
# a second copy would drift the next time a field is added.
# shellcheck disable=SC2016  # $0 is awk's record, not a shell expansion
AWK_META='
$0 == "" { next }
{ n = jarr($0, "plan", a); for (i = 1; i <= n; i++) print "plan" TAB a[i]
  n = jarr($0, "skills", a); for (i = 1; i <= n; i++) print "skill" TAB a[i]
  n = jarr($0, "acceptance", a); for (i = 1; i <= n; i++) print "acceptance" TAB a[i]
  if (jhas($0, "facts")) print "facts" TAB jstr($0, "facts")
  if (jhas($0, "location")) print "location" TAB jstr($0, "location") }
'

# `set_index_field`: one key of one entry rewritten, every other line passed
# through byte-identical.
# shellcheck disable=SC2016  # $0 is awk's record, not a shell expansion
AWK_SET='
$0 == "" { next }
{ if (jstr($0, "id") == ENVIRON["RADIN_ID"])
    print jsplice($0, ENVIRON["RADIN_KEY"], ENVIRON["RADIN_RAW"])
  else print }
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

# Write-time validation for one index-line field value. `meta` emits
# TAB-separated lines, so a TAB, CR or LF is what actually corrupts a reader;
# an acceptance criterion written as a markdown bullet is rejected by name
# instead of being silently stripped.
require_meta_value() {
	local key="$1" value="$2"
	[ -n "$value" ] || die "$key value must not be empty"
	[ "$(printf '%s' "$value" | tr -d '\t\r\n')" = "$value" ] ||
		die "$key value must not contain a tab, carriage return or newline: $value"
	[ "$key" = acceptance ] || return 0
	case "$value" in
	'- '* | '[ ]'* | '[x]'* | '[X]'*)
		die "acceptance takes one criterion as bare text, with no \"- \" bullet and no \"[ ]\" checkbox: $value"
		;;
	esac
}

# The five fields that live on the index line must not also be written into a
# task body: one copy, one parser, one place to fix a malformed value. Matched
# on the exact label prefix, so the prose `**Fact:**` label is not caught by
# the `**Facts:**` rule.
require_no_moved_label() {
	local line
	while IFS= read -r line || [ -n "$line" ]; do
		case "$line" in
		'**Plan:**'* | '**Skill:**'* | '**Acceptance:**'* | '**Facts:**'* | '**Location:**'*)
			die "that label lives on the index line now, not in the body: ${line}
write it with \`add --skill\`, \`add-plan\` or \`backlog set-meta\` instead"
			;;
		esac
	done <<<"$1"
}

slugify() {
	printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
}

# Space-separated task ids from a raw "depends_on" array; empty when unset.
deps_ids() {
	printf '%s' "$1" | tr -d '[]" ' | tr ',' ' '
}

# JSON array literal for the values in "$@", each escaped, or nothing when
# there are none: an empty array and an absent key mean the same thing on the
# index line. awk parses these back (jarr), so an element may hold a space, a
# comma, a `]` or a quote.
# JSON string literal for $1, escaped: what set_index_field wants for a
# string-valued key, where an integer or array key takes its raw text.
json_string() {
	printf '"%s"\n' "$(json_escape "$1")"
}

json_array() {
	local out="" a
	for a in "$@"; do
		[ -z "$out" ] || out="$out,"
		out="$out\"$(json_escape "$a")\""
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

# One index line. An empty $5 omits the key entirely, so an entry with no skill
# carries no "skills" key. Only `add` calls it: every other key reaches a line
# through jsplice, which needs no positional shape and cannot re-escape what is
# already escaped.
compose_line() {
	local out
	out="$(printf '{"id":"%s","category":"%s","title":"%s","file":"%s"' \
		"$1" "$2" "$(json_escape "$3")" "$4")"
	[ -z "$5" ] || out="$out,\"skills\":$5"
	printf '%s}\n' "$out"
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
# new pre-escaped raw JSON value, and an empty $3 drops the key. A key the
# caller does not name is always kept, so no argument ever has to mean "leave
# this alone".
set_index_field() {
	local out
	export RADIN_ID="$1" RADIN_KEY="$2" RADIN_RAW="$3"
	out="$(awk "$AWK_JSON$AWK_SET" "$BACKLOG_INDEX")"
	[ -z "$out" ] || out="$out
"
	write_index "$out"
}

# Drop id $1 from every other entry's depends_on: a dangling reference stalls
# `radin state deps-check` exactly like a cycle does.
prune_dep() {
	local gone="$1" line raw dep kept affected=""
	while IFS= read -r line || [ -n "$line" ]; do
		[ -n "$line" ] || continue
		raw="$(json_get_raw depends_on "$line")"
		case "$raw" in *"\"$gone\""*) affected="$affected $(json_get id "$line")" ;; esac
	done <"$BACKLOG_INDEX"
	for dep in $affected; do
		line="$(grep -F "\"id\":\"$dep\"" "$BACKLOG_INDEX" || true)"
		kept=""
		for raw in $(deps_ids "$(json_get_raw depends_on "$line")"); do
			[ "$raw" = "$gone" ] || kept="$kept $raw"
		done
		# shellcheck disable=SC2086
		set_index_field "$dep" depends_on "$(json_array $kept)"
	done
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

# The `meta` lines of one raw index line: the one reader of the five
# index-line fields, shared by `meta`, `field`, `plan-target` and `show`.
meta_of_line() {
	printf '%s\n' "$1" | awk "$AWK_JSON$AWK_META"
}

# Skills an execution sub-agent cannot run: it has no user to ask, no
# sub-agent of its own, no `Workflow` tool, and a radin entry point would
# recurse (docs/technical-constraints.md has the why for each).
# Written with the leading slash a user would type, so tests/skill-names.bats
# pins each one to a skill radin or a companion actually ships.
SKILL_DENY="/mattpocock-skills:grilling /mattpocock-skills:research /deep-research /radin-execute /radin-implement /radin-plan /radin-review"

# The canonical skill instruction sentence, in one place: `add --skill` and
# `set-meta skills` both compose it here, so no skill writes it by hand.
skill_instruction() {
	printf 'Invoke %s to tackle this task.\n' "$1"
}

# The leading `/<name>` token of a skill instruction, empty when it has none.
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
	rows="$(awk "$AWK_JSON"'$0 != "" { print jstr($0, "category") US fepic(jstr($0, "file")) US jstr($0, "title") US jstr($0, "file") US $0 }' "$BACKLOG_INDEX")"
	for cat in $cats; do
		# One pass in `file` order: flat tasks first, then each epic's
		# children below its shared context, so a human reading `show`
		# sees the hierarchy the `file` paths encode.
		section="$(printf '%s\n' "$rows" | awk -F"$US" -v c="$cat" '$1 == c' | sort -s -t"$US" -k2,2)"
		[ -n "$section" ] || continue
		printf '\n## %s\n' "$cat"
		cur=""
		while IFS="$US" read -r rcat epic title file jline; do
			[ -n "$rcat" ] || continue
			if [ "$epic" != "$cur" ]; then
				cur="$epic"
				printf '\n### epic: %s\n' "$epic"
				[ ! -s "$BACKLOG_TASKS_DIR/$epic/DESCRIPTION.md" ] ||
					cat "$BACKLOG_TASKS_DIR/$epic/DESCRIPTION.md"
			fi
			if [ -z "$epic" ]; then level='###'; else level='####'; fi
			printf '\n%s %s\n' "$level" "$title"
			# The index-line fields through the same parser `meta` uses, so the
			# human view can never drift from the verb -- and a criterion a
			# human wrote is never silently missing from `show`.
			meta_of_line "$jline"
			cat "$(task_path "$file")"
		done <<-SECTION
			$section
		SECTION
	done
	;;

list)
	require_index
	shift
	RADIN_PLANNED=""
	order=priority
	while [ $# -gt 0 ]; do
		case "$1" in
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
		*) usage_die list "unknown list option: $1" ;;
		esac
	done
	# Priority descending with unset last is the ordering contract, not a
	# display choice: a consumer reads this order as the human's ranking.
	# -s keeps equal priorities in index order, and the rank class in field 1
	# is what puts every unset priority after every set one.
	# --order created is index order, which is creation order because
	# index.jsonl is append-only: the TUI wants a list no mutation reorders.
	export RADIN_PLANNED
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
	skill_list=()
	while [ $# -gt 0 ]; do
		case "$1" in
		--skill)
			[ -n "${2:-}" ] || usage_die add "--skill needs a name"
			skill_list[${#skill_list[@]}]="$(skill_instruction "$2")"
			shift 2
			;;
		*) usage_die add "unknown add option: $1" ;;
		esac
	done
	require_plain_title "$title"
	BODY="$(cat)"
	[ -n "$BODY" ] || die "entry body is empty (pass it on stdin)"
	require_no_moved_label "$BODY"
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
	rel="tasks/$id.md"
	task_file="$(task_path "$rel")"
	printf '%s\n' "$BODY" >"$task_file"
	skills_array=""
	[ "${#skill_list[@]}" -eq 0 ] || skills_array="$(json_array "${skill_list[@]}")"
	compose_line "$id" "$category" "$title" "$rel" "$skills_array" >>"$BACKLOG_INDEX"
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
	meta_of_line "$(single_match "$2")"
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
	TASK_BODY)
		# The execution prompt inlines the body instead of naming the file, so
		# the leaf spends no read on its own task. An empty file is a broken
		# entry (`add` refuses one), hence exit 1 rather than an empty prompt.
		file="$(entry_path "$entry")"
		[ -s "$file" ] || exit 1
		cat "$file"
		;;
	EPIC_CONTEXT)
		# A task inside an epic inherits the epic's DESCRIPTION.md; a flat task
		# and an empty description both exit 1, the "drop the whole block"
		# contract FACTS and LOCATION use.
		epic="$(file_epic "$(json_get file "$entry")")"
		[ -n "$epic" ] || exit 1
		[ -s "$BACKLOG_TASKS_DIR/$epic/DESCRIPTION.md" ] || exit 1
		cat "$BACKLOG_TASKS_DIR/$epic/DESCRIPTION.md"
		;;
	FACTS | LOCATION)
		key=facts
		[ "$fname" = FACTS ] || key=location
		# Exit 1 with no output is the caller's "delete the whole line" signal,
		# the same contract PLAN_PATHS and ACCEPTANCE already use.
		value="$(meta_of_line "$entry" | sed -n "s/^$key$TAB//p")"
		[ -n "$value" ] || exit 1
		printf '%s\n' "$value"
		;;
	PLAN_PATHS | SKILLS | SKILLS_DROPPED | ACCEPTANCE)
		meta="$(meta_of_line "$entry")"
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

append)
	[ -n "${2:-}" ] || usage_die append "append needs an id or title, with the text on stdin"
	require_index
	entry="$(single_match "$2")"
	BODY="$(cat)"
	[ -n "$BODY" ] || die "append text is empty (pass it on stdin)"
	require_no_moved_label "$BODY"
	printf '\n%s\n' "$BODY" >>"$(entry_path "$entry")"
	printf 'appended to "%s"\n' "$(json_get title "$entry")"
	;;

add-plan)
	query="${2:-}"
	plan_path="${3:-}"
	[ -n "$plan_path" ] || usage_die add-plan "add-plan needs an id or title and a plan path"
	require_index
	entry="$(single_match "$query")"
	require_meta_value plan "$plan_path"
	# Append semantics: a split plan points at several files, in order.
	plan_list=()
	while IFS= read -r pline || [ -n "$pline" ]; do
		[ -n "$pline" ] || continue
		plan_list[${#plan_list[@]}]="${pline#plan"$TAB"}"
	done <<-PLANS
		$(meta_of_line "$entry" | grep "^plan$TAB" || true)
	PLANS
	plan_list[${#plan_list[@]}]="$plan_path"
	set_index_field "$(json_get id "$entry")" plan "$(json_array "${plan_list[@]}")"
	printf 'plan pointer added to "%s"\n' "$(json_get title "$entry")"
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
	meta="$(meta_of_line "$found")"
	facts="$(printf '%s\n' "$meta" | grep "^facts$TAB" || true)"
	[ -z "$facts" ] || printf '%s\n' "$facts"
	plans="$(printf '%s\n' "$meta" | grep "^plan$TAB" || true)"
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
	set_index_field "$id" category "$(json_string "$newcat")"
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
	set_index_field "$id" title "$(json_string "$newtitle")"
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
		dep_array="$(json_array $deps)"
	fi
	set_index_field "$id" depends_on "$dep_array"
	printf 'depends_on of %s set to %s\n' "$id" "$value"
	;;

set-meta)
	query="${2:-}"
	key="${3:-}"
	[ -n "$key" ] || usage_die set-meta "set-meta needs an id or title, a key, and a value or --none"
	case "$key" in
	plan | skills | acceptance | facts | location) ;;
	*) usage_die set-meta "key must be plan|skills|acceptance|facts|location, got: $key" ;;
	esac
	shift 3
	[ $# -gt 0 ] || usage_die set-meta "set-meta needs at least one value, or --none"
	require_index
	entry="$(single_match "$query")"
	id="$(json_get id "$entry")"
	if [ "$1" = "--none" ]; then
		[ $# -eq 1 ] || usage_die set-meta "--none takes no other value, got: $2"
		raw=""
	else
		case "$key" in
		facts | location)
			[ $# -eq 1 ] || usage_die set-meta "$key takes exactly one value, got $#"
			;;
		esac
		# skills takes skill names, like `add --skill`: the instruction
		# sentence is composed here so no caller writes it by hand.
		meta_vals=()
		for v in "$@"; do
			[ "$key" != skills ] || v="$(skill_instruction "$v")"
			require_meta_value "$key" "$v"
			meta_vals[${#meta_vals[@]}]="$v"
		done
		case "$key" in
		facts | location) raw="$(json_string "${meta_vals[0]}")" ;;
		*) raw="$(json_array "${meta_vals[@]}")" ;;
		esac
	fi
	set_index_field "$id" "$key" "$raw"
	if [ -z "$raw" ]; then
		printf '%s of %s cleared\n' "$key" "$id"
	else
		printf '%s of %s set\n' "$key" "$id"
	fi
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
	# task-done) BEFORE its backlog entry is removed. If the run dies
	# between those two steps the completed entry stays in the backlog and
	# looks unstarted next session. Reconcile closes that gap: drop every
	# backlog entry whose id already sits in completed.json.
	# ponytail: id-keyed match. A brand-new task that reuses a removed
	# task's slug (same title) would be dropped too; clear completed.json
	# between sessions if that ever bites.
	completed_file="$NAMESPACE_DIR/state/completed.json"
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
	set_index_field "$id" file "$(json_string "$new_rel")"
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
