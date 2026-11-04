#!/usr/bin/env bats
# Every `/<name>` skill invocation written in skills/**/SKILL.md, lib/*.md,
# lib/radin-backlog.sh and lib/radin-scope.sh must resolve to a skill radin ships itself or one install.sh installs as a
# companion. A renamed or mistyped name costs a failed call plus a fallback in
# every sub-agent that reads the prompt, silently.
#
# The companion list is hardcoded below, mirroring install.sh -- resolving
# against a live ~/.claude would make this suite machine-dependent.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

  # Plugin prefixes install.sh installs (install_plugin calls).
  PLUGINS="caveman ponytail mattpocock-skills"
  # Unprefixed companions install.sh installs directly.
  COMPANIONS="thermo-nuclear"
  # Names written as illustrations of what a *user* may type, not as radin
  # delegations: a workflow command and two placeholder skill names.
  EXAMPLES="deep-research frontend-design other-skill"
  # Not skill names at all: `bin` comes off a `/bin/bash` shebang path, `dev`
  # off awk's `/dev/stderr` in lib/radin-backlog.sh, `host` off the
  # `<!-- /host -->` marker that closes a host block.
  NOT_SKILLS="bin dev host"
}

# Slash tokens, allowing leading markdown emphasis, backticks, quotes and one
# `=` (a name inside a shell string literal, as radin-scope.sh's `passes`
# values are) but requiring whitespace or line start before them -- so
# `git diff`/reading is not a hit.
skill_tokens() {
  cd "$REPO_ROOT" || return 1
  grep -ohE "(^|[[:space:]=])[*_('\"]*\`?/[a-z0-9][a-z0-9:-]*" \
    skills/*/SKILL.md lib/*.md lib/radin-backlog.sh lib/radin-scope.sh |
    tr -d "\`*_( '\"=" | sed 's|^/||' | sort -u
}

@test "every /<skill> name in skills/ and lib/ resolves to a shipped skill" {
  run skill_tokens
  [ "$status" -eq 0 ]
  [ -n "$output" ]

  unknown=""
  for token in $output; do
    case "$token" in
      *:*)
        prefix="${token%%:*}"
        case " $PLUGINS " in
          *" $prefix "*) continue ;;
        esac
        ;;
      *)
        [ -f "$REPO_ROOT/skills/$token/SKILL.md" ] && continue
        case " $COMPANIONS $EXAMPLES $NOT_SKILLS " in
          *" $token "*) continue ;;
        esac
        ;;
    esac
    unknown="$unknown $token"
  done

  [ -z "$unknown" ] || {
    echo "unresolvable skill names:$unknown"
    false
  }
}

# The Skill tool refuses a model-side call to a skill with
# `disable-model-invocation`, so no other skill may tell the model to run one.
@test "no skill invokes a disable-model-invocation skill" {
  cd "$REPO_ROOT"
  hits=""
  for f in $(grep -l '^disable-model-invocation: true' skills/*/SKILL.md); do
    name="$(basename "$(dirname "$f")")"
    for g in skills/*/SKILL.md; do
      [ "$g" = "$f" ] && continue
      grep -qE "invoke \`/$name\`" "$g" && hits="$hits $g->$name"
    done
  done
  [ -z "$hits" ] || {
    echo "model-side invocation of a user-only skill:$hits"
    false
  }
}

@test "both skill-name tables hold the same keys, with valid and matching values" {
  cd "$REPO_ROOT/lib"
  keys() { grep -vE '^(#|$)' "$1" | awk '{ print $1 }'; }
  [ "$(keys skill-names-claude.txt)" = "$(keys skill-names-agents.txt)" ]
  while read -r k v; do
    a="$(awk -v k="$k" '$1 == k { print $2 }' skill-names-agents.txt)"
    case "$v" in
      /*:*) prefix="${v#/}"; prefix="${prefix%%:*}"; case " $PLUGINS " in *" $prefix "*) ;; *) echo "bad plugin $v"; false ;; esac; name="${v##*:}" ;;
      /*) name="${v#/}"; case " $COMPANIONS " in *" $name "*) ;; *) echo "bad companion $v"; false ;; esac ;;
      *) echo "claude value without slash: $v"; false ;;
    esac
    [ "$a" = "$name" ] || { echo "$k: agents value $a, want $name"; false; }
    [ "$k" = "$name" ] || { echo "$k: key differs from skill name $name"; false; }
  done < <(grep -vE '^(#|$)' skill-names-claude.txt)
}

@test "every @@skill:NAME@@ token in the sources resolves in both tables" {
  cd "$REPO_ROOT"
  run grep -ohE '@@skill:[a-z0-9-]+@@' skills/*/SKILL.md lib/*.md lib/*.sh
  [ "$status" -eq 0 ]
  for t in $(printf '%s\n' "$output" | sort -u); do
    k="${t#@@skill:}"; k="${k%@@}"
    for h in claude agents; do
      awk -v k="$k" '$1 == k { f = 1 } END { exit !f }' lib/skill-names-$h.txt || { echo "$k missing from $h"; false; }
    done
  done
}

@test "companion-skills.txt has a well-formed row for every agents skill name" {
  cd "$REPO_ROOT/lib"
  rows() { grep -vE '^(#|$)' companion-skills.txt; }
  [ "$(rows | awk 'NF != 4' | wc -l | tr -d ' ')" = 0 ]
  [ "$(rows | awk '{ print $1 }' | sort | uniq -d)" = "" ]
  while read -r n c b f; do
    case " caveman ponytail mattpocock-skills pstack " in *" $c "*) ;; *) echo "$n: bad companion $c"; false ;; esac
    case "$b" in https://raw.githubusercontent.com/*) ;; *) echo "$n: bad base $b"; false ;; esac
    case "$f" in SKILL.md|SKILL.md,*) ;; *) echo "$n: files must start with SKILL.md"; false ;; esac
  done < <(rows)
  for k in $(grep -vE '^(#|$)' skill-names-agents.txt | awk '{ print $1 }'); do
    rows | awk -v k="$k" '$1 == k { f = 1 } END { exit !f }' || { echo "$k missing from companion-skills.txt"; false; }
  done
}
