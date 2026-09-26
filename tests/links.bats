#!/usr/bin/env bats
# Every relative markdown link, `#anchor` and `RADIN_LIB/<doc>.md` path in the
# prose radin ships or keeps must resolve. A dangling one sends a model to read
# a file or section that is not there, and nothing else notices.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

# GitHub's heading slug: lowercase, punctuation dropped, spaces to hyphens.
slugs() {
  sed -n 's/^#\{1,6\} //p' "$1" | tr '[:upper:]' '[:lower:]' |
    sed -e 's/[^a-z0-9 _-]//g' -e 's/ /-/g'
}

@test "every relative link and anchor in the repo's markdown resolves" {
  cd "$REPO_ROOT" || return 1
  bad=""
  for f in *.md docs/*.md lib/*.md skills/*/SKILL.md; do
    dir="$(dirname "$f")"
    for link in $(grep -oE '\]\([^)[:space:]]+\)' "$f" | sed -e 's/^](//' -e 's/)$//'); do
      case "$link" in http:* | https:* | mailto:*) continue ;; esac
      path="${link%%#*}"
      anchor=""
      [ "$path" = "$link" ] || anchor="${link#*#}"
      target="$f"
      [ -z "$path" ] || target="$dir/$path"
      if [ ! -e "$target" ]; then
        bad="$bad $f:$link"
        continue
      fi
      [ -n "$anchor" ] || continue
      [ -f "$target" ] || continue
      slugs "$target" | grep -qx -- "$anchor" || bad="$bad $f:$link"
    done
  done
  [ -z "$bad" ] || { echo "unresolved:$bad"; false; }
}

@test "every RADIN_LIB doc a skill or lib file names exists in lib/" {
  cd "$REPO_ROOT" || return 1
  bad=""
  for doc in $(grep -ohE 'RADIN_LIB/[A-Za-z0-9_.-]+\.md' skills/*/SKILL.md lib/*.md | sort -u); do
    [ -f "lib/${doc#RADIN_LIB/}" ] || bad="$bad $doc"
  done
  [ -z "$bad" ] || { echo "missing:$bad"; false; }
}
