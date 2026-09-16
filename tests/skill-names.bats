#!/usr/bin/env bats
# Every `/<name>` skill invocation written in skills/**/SKILL.md, lib/*.md and
# lib/radin-backlog.sh must resolve to a skill radin ships itself or one install.sh installs as a
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
  # Not a skill name at all: `bin` comes off the `/bin/bash` path in
  # lib/radin-backlog.sh's header.
  NOT_SKILLS="bin"
}

# Slash tokens, allowing leading markdown emphasis/backticks but requiring
# whitespace or line start before them -- so `git diff`/reading is not a hit.
skill_tokens() {
  cd "$REPO_ROOT" || return 1
  grep -ohE '(^|[[:space:]])[*_(]*`?/[a-z0-9][a-z0-9:-]*' \
    skills/*/SKILL.md lib/*.md lib/radin-backlog.sh |
    tr -d '`*_( ' | sed 's|^/||' | sort -u
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

@test "the extractor sees the names radin actually delegates to" {
  run skill_tokens
  [ "$status" -eq 0 ]
  for expected in radin-plan thermo-nuclear ponytail:ponytail \
    caveman:caveman-commit mattpocock-skills:grilling; do
    [[ "$output" == *"$expected"* ]] || {
      echo "extractor missed $expected"
      false
    }
  done
}

@test "the execution fence states the STATUS contract before its numbered steps" {
  f="$REPO_ROOT/lib/radin-execute-prompts.md"
  contract="$(grep -n 'STATUS: SUCCESS' "$f" | head -1 | cut -d: -f1)"
  first_step="$(grep -n '^1\. Read TASK_FILE' "$f" | head -1 | cut -d: -f1)"
  [ -n "$contract" ]
  [ -n "$first_step" ]
  [ "$contract" -lt "$first_step" ]
}
