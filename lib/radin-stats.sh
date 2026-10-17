#!/usr/bin/env bash
# radin stats: how the skill stack is used on this device.
# Reads Claude Code transcripts (skills, slash commands, sub-agents and their
# outcomes) and every radin repo's journal. Read-only. Installed to
# ~/.claude/.radin/lib/radin-stats.sh by install.sh.
# Must stay bash-3.2-compatible (macOS /bin/bash).
#
#   radin-stats.sh [--since YYYY-MM-DD] [--repos-root DIR] [--no-transcripts] [--no-repos]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
since="" repos_root="$HOME/Documents" do_tx=1 do_repos=1
while [ $# -gt 0 ]; do
	case "$1" in
	--since)
		since="${2:?--since needs a date}"
		shift
		;;
	--repos-root)
		repos_root="${2:?--repos-root needs a dir}"
		shift
		;;
	--no-transcripts) do_tx=0 ;;
	--no-repos) do_repos=0 ;;
	*)
		printf 'usage: radin stats [--since YYYY-MM-DD] [--repos-root DIR] [--no-transcripts] [--no-repos]\n' >&2
		exit 1
		;;
	esac
	shift
done

TAB="$(printf '\t')"
table() { # $1 title, stdin: TSV with header line first
	printf '\n== %s\n' "$1"
	column -t -s "$TAB"
}

transcripts() {
	local root="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects"
	[ -d "$root" ] || {
		printf 'radin stats: no transcripts at %s\n' "$root" >&2
		return 0
	}
	# The grep prefilter keeps awk off the other 99% of a multi-hundred-MB corpus.
	# "./" keeps the dash-leading project dir names from reading as options.
	# Attachment lines embed escaped copies of the tool list; skip them.
	(cd "$root" && find . -maxdepth 2 -name '*.jsonl' -print0 |
		xargs -0 grep -H -E '"name":"(Skill|Agent)","input":|<command-name>/|<task-notification>|"type":"hook_' 2>/dev/null |
		grep -v -E '"attachment":\{"type":"([^h]|h[^o])' || true) |
		awk -v since="$since" -v out="$OUT_DIR" '
function vendor(n) {
	if (n ~ /^radin/) return "radin"
	if (index(n, ":")) return substr(n, 1, index(n, ":") - 1)
	return "other"
}
function day(l,   t) { if (match(l, /"timestamp":"[0-9-]+/)) return substr(l, RSTART + 13, RLENGTH - 13); return "" }
{
	i = index($0, ":"); f = substr($0, 1, i - 1); l = substr($0, i + 1)
	split(f, p, "/"); proj = p[2]
	d = day(l)
	if (since != "" && d != "" && d < since) next
	if (d != "") { if (mn == "" || d < mn) mn = d; if (d > mx) mx = d }
	if (match(l, /"attachment":\{"type":"hook_[a-z_]+"/)) {
		ht = substr(l, RSTART + 22, RLENGTH - 23)
		hn = "-"; if (match(l, /"hookName":"[^"]+"/)) hn = substr(l, RSTART + 12, RLENGTH - 13)
		hid = ""; if (match(l, /"toolUseID":"[^"]+"/)) hid = substr(l, RSTART + 14, RLENGTH - 15)
		lab = "(no output)"
		if (ht == "hook_cancelled") { if (match(l, /"command":"[^"]+"/)) lab = substr(l, RSTART + 11, RLENGTH - 12) }
		else if (ht == "hook_non_blocking_error") { if (match(l, /executing hook command: [^"]{1,60}/)) lab = substr(l, RSTART + 24, RLENGTH - 24) }
		else if (match(l, /"content":\[?"[^"\\]{2,40}/)) lab = substr(l, RSTART, RLENGTH)
		else if (match(l, /permissionDecisionReason\\":\\"[^\\]+/)) { lab = substr(l, RSTART, RLENGTH); sub(/^.*\\":\\"/, "", lab) }
		else if (match(l, /additionalContext\\":\\"\[[a-z-]+\]/)) lab = substr(l, RSTART + 22, RLENGTH - 22)
		sub(/^"content":\[?"/, "", lab)
		key = hn SUBSEP lab
		# One hook can log twice (stream and replay); count it once per run.
		if (!((hid, key, ht) in seen)) {
			seen[hid, key, ht] = 1; hooks[key] = 1
			hs[key, ht == "hook_cancelled" ? "cancel" : (ht == "hook_non_blocking_error" ? "err" : "ok")]++
			hf[key, f] = 1; if (d > hlast[key]) hlast[key] = d
		}
		next
	}
	if (match(l, /"id":"toolu_[A-Za-z0-9]+","name":"Skill","input":\{"skill":"[^"]+"/)) {
		s = substr(l, RSTART, RLENGTH); id = s; sub(/^"id":"/, "", id); sub(/".*/, "", id)
		if (!(id in seen)) {
			seen[id] = 1; sub(/.*"skill":"/, "", s); sub(/"$/, "", s)
			sk[s, "tool"]++; names[s] = 1; sf[s, f] = 1; sp[s, proj] = 1; if (d > last[s]) last[s] = d
		}
	}
	if (match(l, /<command-name>\/[A-Za-z0-9:_.-]+<\/command-name>/)) {
		s = substr(l, RSTART + 15, RLENGTH - 30)
		sk[s, "typed"]++; names[s] = 1; sf[s, f] = 1; sp[s, proj] = 1; if (d > last[s]) last[s] = d
	}
	if (match(l, /"id":"toolu_[A-Za-z0-9]+","name":"Agent","input":/)) {
		id = substr(l, RSTART + 6, RLENGTH); sub(/".*/, "", id)
		if (!(id in seen)) {
			seen[id] = 1; t = "general-purpose"; m = "inherit"
			rest = substr(l, RSTART)
			if (match(rest, /"subagent_type":"[^"]+"/)) t = substr(rest, RSTART + 17, RLENGTH - 18)
			if (match(rest, /"model":"[^"]+"/)) m = substr(rest, RSTART + 9, RLENGTH - 10)
			ag[t, "calls"]++; types[t] = 1; type_of[id] = t; mdl[t, m]++
		}
	}
	if (index(l, "<task-notification>")) {
		if (!match(l, /<task-id>[^<]+/)) next; tid = substr(l, RSTART + 9, RLENGTH - 9)
		tu = ""; if (match(l, /<tool-use-id>[^<]+/)) tu = substr(l, RSTART + 13, RLENGTH - 13)
		st = "?"; if (match(l, /<status>[^<]+/)) st = substr(l, RSTART + 8, RLENGTH - 8)
		tk = 0; if (match(l, /<subagent_tokens>[0-9]+/)) tk = substr(l, RSTART + 17, RLENGTH - 17)
		tl = 0; if (match(l, /<tool_uses>[0-9]+/)) tl = substr(l, RSTART + 11, RLENGTH - 11)
		ms = 0; if (match(l, /<duration_ms>[0-9]+/)) ms = substr(l, RSTART + 13, RLENGTH - 13)
		# The same task-id notifies again when resumed; the last one wins.
		n_type[tid] = tu; n_st[tid] = st; n_tk[tid] = tk; n_tl[tid] = tl; n_ms[tid] = ms
	}
}
END {
	print mn " to " mx > (out "/span.txt")
	f1 = out "/skills.tsv"; f2 = out "/agents.tsv"; f3 = out "/vendors.tsv"; f4 = out "/hooks.tsv"
	print "vendor\tskill\ttool-calls\ttyped\tsessions\tprojects\tlast" > f1
	for (s in names) {
		ns = 0; for (k in sf) { split(k, a, SUBSEP); if (a[1] == s) ns++ }
		np = 0; for (k in sp) { split(k, a, SUBSEP); if (a[1] == s) np++ }
		printf "%s\t%s\t%d\t%d\t%d\t%d\t%s\n", vendor(s), s, sk[s, "tool"], sk[s, "typed"], ns, np, last[s] > f1
		v[vendor(s)] += sk[s, "tool"] + sk[s, "typed"]
	}
	for (tid in n_type) {
		t = (n_type[tid] in type_of) ? type_of[n_type[tid]] : "?"
		if (t == "?") continue
		o[t, n_st[tid]]++; tok[t] += n_tk[tid]; tls[t] += n_tl[tid]; dur[t] += n_ms[tid]; fin[t]++
	}
	print "vendor\tsub-agent\tcalls\tfinished\tcompleted\tfailed\tother\tavg-tokens\tavg-tools\tavg-sec\tmodels" > f2
	for (t in types) {
		c = o[t, "completed"] + 0; fl = o[t, "failed"] + 0; ot = fin[t] - c - fl
		ml = ""; for (k in mdl) { split(k, a, SUBSEP); if (a[1] == t) ml = ml a[2] "=" mdl[k] " " }
		n = fin[t] ? fin[t] : 1
		printf "%s\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%.1f\t%.0f\t%s\n", (t ~ /:/ ? vendor(t) : "built-in"), t, ag[t, "calls"], fin[t] + 0, c, fl, ot, tok[t] / n, tls[t] / n, dur[t] / n / 1000, ml > f2
		av[(t ~ /:/ ? vendor(t) : "built-in")] += ag[t, "calls"]
	}
	print "event\thook\tran\tcancelled\terrors\tsessions\tlast" > f4
	for (k in hooks) {
		split(k, a, SUBSEP); ns = 0
		for (j in hf) { split(j, b, SUBSEP); if (b[1] SUBSEP b[2] == k) ns++ }
		printf "%s\t%s\t%d\t%d\t%d\t%d\t%s\n", a[1], a[2], hs[k, "ok"], hs[k, "cancel"], hs[k, "err"], ns, hlast[k] > f4
	}
	print "vendor\tuses (skills + sub-agents)" > f3
	for (k in v) w[k] = v[k]
	for (k in av) w[k] += av[k]
	for (k in w) printf "%s\t%d\n", k, w[k] > f3
}'
}

# Per completed task: did a fix/revert commit touch the same non-markdown files
# within 14 days? A proxy for "the first attempt was wrong", not a verdict.
outcomes() {
	local d r n list
	printf 'repo\ttasks\tmissing\trefixed\treverted\tclean%%\n'
	for d in "$repos_root"/*/.claude/.radin; do
		[ -d "$d" ] || continue
		r="${d%/.claude/.radin}"
		n="$(basename "$r")"
		list="$(cd "$r" && bash "$HERE/radin-state.sh" completed-list 2>/dev/null || true)"
		[ -n "$list" ] || continue
		printf "%s\n" "$list" >"$OUT_DIR/done.tsv"
		(cd "$r" && git log --format="%x01%H %ct %s" --name-only 2>/dev/null || true) |
			awk -v n="$n" -v since="$since" -v listfile="$OUT_DIR/done.tsv" '
			BEGIN { while ((getline line < listfile) > 0) { split(line, p, "\t"); want[p[2]] = 1 } }
			/^\001/ { c++; h[c] = substr($1, 2); ts[c] = $2; s = $0; sub(/^[^ ]+ [0-9]+ /, "", s); subj[c] = s; next }
			NF && $0 !~ /\.md$/ { nf[c]++; fl[c, nf[c]] = $0; byfile[$0] = byfile[$0] " " c }
			END {
				for (k = 1; k <= c; k++) for (w in want) if (substr(h[k], 1, length(w)) == w) { idx[w] = k; isdone[k] = 1 }
				for (w in want) {
					tot++
					if (!(w in idx)) { miss++; continue }
					k = idx[w]; bad = 0; rev = 0
					for (q = 1; q <= nf[k]; q++) {
						t = split(byfile[fl[k, q]], J, " ")
						for (z = 1; z <= t; z++) {
							j = J[z]
							if (!isdone[j] && j < k && ts[j] > ts[k] && ts[j] <= ts[k] + 1209600 && subj[j] ~ /^(fix|revert)(\(|:|!| )/) { bad = 1; if (subj[j] ~ /^revert/) rev = 1 }
						}
					}
					fx += bad; rv += rev
				}
				ok = tot - miss
				printf "%s\t%d\t%d\t%d\t%d\t%.0f\n", n, tot, miss, fx, rv, ok ? 100 * (ok - fx) / ok : 0
			}'
	done
}

repos() {
	local d r n open
	printf 'repo\topen\tstarted\tdone\tfailed\tblocked\tdebug\tsub-agent-tokens\tsub-agent-tools\tsub-agent-min\n'
	for d in "$repos_root"/*/.claude/.radin; do
		[ -d "$d" ] || continue
		r="${d%/.claude/.radin}"
		n="$(basename "$r")"
		open="$(cd "$r" && bash "$HERE/radin-backlog.sh" count 2>/dev/null || printf '?')"
		(cd "$r" && bash "$HERE/radin-state.sh" journal-tail 1000000 2>/dev/null || true) |
			awk -v n="$n" -v open="$open" -v since="$since" '
			{
				if (since != "" && match($0, /"ts":"[0-9-]+/) && substr($0, RSTART + 6, RLENGTH - 6) < since) next
				if (!match($0, /"event":"[a-z_-]+"/)) next
				e = substr($0, RSTART + 9, RLENGTH - 10); c[e]++
				if (e == "usage" && match($0, /"detail":"[a-z]+ [0-9]+ [0-9]+ [0-9]+"/)) {
					split(substr($0, RSTART + 10, RLENGTH - 11), u, " "); tk += u[2]; tl += u[3]; ms += u[4]
				}
			}
			END { printf "%s\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%.1f\n", n, open, c["in_progress"], c["done"], c["failed"], c["blocked"], c["debug"], tk, tl, ms / 60000 }'
	done
}

OUT_DIR="$(mktemp -d)"
trap 'rm -rf "$OUT_DIR"' EXIT
if [ "$do_tx" -eq 1 ]; then
	transcripts
	if [ -s "$OUT_DIR/skills.tsv" ]; then
		printf 'Transcripts: %s, %s (older sessions are pruned by Claude Code)%s\n' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects" "$(cat "$OUT_DIR/span.txt")" "${since:+ (since $since)}"
		{
			sed -n 1p "$OUT_DIR/vendors.tsv"
			tail -n +2 "$OUT_DIR/vendors.tsv" | sort -t "$TAB" -k2,2nr
		} | table "Stack by vendor"
		{
			sed -n 1p "$OUT_DIR/skills.tsv"
			tail -n +2 "$OUT_DIR/skills.tsv" | sort -t "$TAB" -k1,1 -k3,3nr -k4,4nr
		} | table "Skills (tool-calls = model invoked it, typed = user ran /name)"
		{
			sed -n 1p "$OUT_DIR/agents.tsv"
			tail -n +2 "$OUT_DIR/agents.tsv" | sort -t "$TAB" -k1,1 -k3,3nr
		} | table "Sub-agents (outcomes from background completions only)"
		{
			sed -n 1p "$OUT_DIR/hooks.tsv"
			tail -n +2 "$OUT_DIR/hooks.tsv" | sort -t "$TAB" -k1,1 -k3,3nr
		} | table "Hooks (one row per hook output; a hook that never fires has no row)"
	else
		printf 'No transcript data found.\n'
	fi
fi
if [ "$do_repos" -eq 1 ]; then
	repos | table "radin repos under $repos_root"
	outcomes | table "Task outcomes (refixed = a fix:/revert: commit that is not itself a radin task touched the same non-markdown files within 14 days of the task commit)"
fi
