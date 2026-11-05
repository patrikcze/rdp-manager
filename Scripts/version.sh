#!/bin/zsh
# Prints the app version from git tags, for the build scripts and CI.
#   Scripts/version.sh            short version for CFBundleShortVersionString, e.g. 0.3.0
#   Scripts/version.sh --full     e.g. 0.3.0, 0.3.0-beta.1, or 0.3.0-dev.4+g1a2b3c4 between tags
#   Scripts/version.sh --build    CFBundleVersion: the commit count, always increasing
# Release tags are vMAJOR.MINOR.PATCH with an optional pre-release suffix (v0.3.0-beta.1).
# A VERSION environment variable overrides the tag (it must be MAJOR.MINOR.PATCH[-suffix]).
set -euo pipefail
cd "${0:A:h:h}"

SEMVER='^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'

full() {
  if [[ -n "${VERSION:-}" ]]; then
    [[ "$VERSION" =~ $SEMVER ]] || { echo "VERSION '$VERSION' is not MAJOR.MINOR.PATCH[-suffix]" >&2; exit 1; }
    print -r -- "$VERSION"
    return
  fi
  local tag
  if tag="$(git describe --tags --exact-match --match 'v[0-9]*' HEAD 2>/dev/null)"; then
    print -r -- "${tag#v}"
    return
  fi
  # Between tags: the last release with a dev suffix; before the first tag, 0.0.0.
  local last="v0.0.0" ahead
  last="$(git describe --tags --abbrev=0 --match 'v[0-9]*' HEAD 2>/dev/null || echo v0.0.0)"
  if [[ "$last" == "v0.0.0" ]]; then
    ahead="$(git rev-list --count HEAD 2>/dev/null || echo 0)"
  else
    ahead="$(git rev-list --count "$last..HEAD")"
  fi
  local base="${last#v}"
  print -r -- "${base%%-*}-dev.$ahead+g$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
}

case "${1:-}" in
  --full) full ;;
  --build) git rev-list --count HEAD 2>/dev/null || echo 1 ;;
  "") v="$(full)"; print -r -- "${v%%[-+]*}" ;;   # Apple wants digits and dots only
  *) echo "usage: $0 [--full|--build]" >&2; exit 2 ;;
esac
