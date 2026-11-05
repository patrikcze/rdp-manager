#!/bin/zsh
# Prints the CHANGELOG.md section of one version, for the GitHub release notes.
#   Scripts/release-notes.sh 0.3.0
# Fails when the section is missing, empty or still marked "(unreleased)".
set -euo pipefail
cd "${0:A:h:h}"

VERSION="${1:?usage: $0 VERSION}"
heading="$(grep -E "^## ${VERSION//./\\.}( |$)" CHANGELOG.md || true)"
[[ -n "$heading" ]] || { echo "CHANGELOG.md has no '## $VERSION' section." >&2; exit 1; }
[[ "$heading" != *unreleased* ]] || { echo "CHANGELOG.md still marks $VERSION as unreleased; give it a date first." >&2; exit 1; }
notes="$(awk -v h="$heading" '$0 == h {found = 1; next} found && /^## / {exit} found {print}' CHANGELOG.md)"
[[ -n "${notes//[[:space:]]/}" ]] || { echo "The $VERSION section of CHANGELOG.md is empty." >&2; exit 1; }
print -r -- "$notes"
