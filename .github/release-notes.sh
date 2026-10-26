#!/bin/sh
# Prints the GitHub release notes for a version:
#   1. the version's summary from CHANGELOG.md (the text before its first ###),
#   2. "About godotnvim", from docs/release/about.md,
#   3. "Changelog": the version's Added, Removed and Fixed sections (other
#      sections, such as Changed, follow Added), with "None." for an empty one.
# Image and link paths are made absolute, pinned to the tag, so screenshots
# render on the release page.
#
# Usage: .github/release-notes.sh <version> [<tag>]   (tag defaults to v<version>)
set -eu
version=$1
tag=${2:-v$version}
raw="https://raw.githubusercontent.com/${GITHUB_REPOSITORY:-gdey/godotnvim}/$tag"

section=$(awk -v v="$version" '/^## \[/ { on = index($0, "[" v "]") > 0; next } /^\[[^]]*\]: / { next } on' CHANGELOG.md)
if [ -z "$section" ]; then
  echo "no CHANGELOG.md section for $version" >&2
  exit 1
fi

# The text of one ### section (without its heading), or the summary for "".
part() {
  printf '%s\n' "$section" | awk -v want="$1" '
    /^### / { cur = substr($0, 5); next }
    cur == want { print }'
}
trim() { sed -e '/./,$!d' | sed -e ':a' -e '/^\n*$/{$d;N;ba' -e '}'; }

{
  part "" | trim
  echo
  echo "## About godotnvim"
  echo
  sed "s|](\.\./|](docs/|g" docs/release/about.md
  echo
  echo "## Changelog"
  others=$(printf '%s\n' "$section" | sed -n 's/^### //p' | grep -vx -e Added -e Removed -e Fixed || true)
  for name in Added $others Removed Fixed; do
    echo
    echo "### $name"
    echo
    body=$(part "$name" | trim)
    if [ -n "$body" ]; then printf '%s\n' "$body"; else echo "None."; fi
  done
} | sed "s|](docs/|]($raw/docs/|g"
