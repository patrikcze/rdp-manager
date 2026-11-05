#!/bin/zsh
# Tags a release. Pushing the tag starts the Release workflow, which builds, tests and
# publishes RDP-Manager-<version>.dmg on GitHub Releases.
#   Scripts/tag-release.sh 0.3.0            or 0.3.0-beta.1 for a pre-release
#   Scripts/tag-release.sh 0.3.0 --push     also pushes the tag
# Requires: on master, clean, up to date with origin, and a "## <version>" section in
# CHANGELOG.md that is not marked "(unreleased)" (its text becomes the release notes).
set -euo pipefail
cd "${0:A:h:h}"

VERSION="${1:-}"
[[ "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$' ]] || { echo "usage: $0 MAJOR.MINOR.PATCH[-suffix] [--push]"; exit 2; }
TAG="v$VERSION"

[[ "$(git branch --show-current)" == "master" ]] || { echo "Release from master."; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "The working tree has changes."; exit 1; }
git fetch --quiet origin master --tags
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/master)" ]] || { echo "master is not the same as origin/master."; exit 1; }
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && { echo "$TAG already exists."; exit 1; }

Scripts/release-notes.sh "$VERSION" >/dev/null   # fails without a finished CHANGELOG section

git tag -a "$TAG" -m "RDP Manager $VERSION"
echo "Tagged $TAG at $(git rev-parse --short HEAD)."
if [[ "${2:-}" == "--push" ]]; then
  git push origin "$TAG"
else
  echo "Push it to publish: git push origin $TAG"
fi
