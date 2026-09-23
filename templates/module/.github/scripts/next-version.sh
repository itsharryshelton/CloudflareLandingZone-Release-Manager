#!/usr/bin/env bash
# Prints the next SemVer tag for HEAD, or nothing when HEAD is already tagged.
#
# The bump is read from every commit since the last tag rather than the head
# commit alone, so a keyword anywhere in a multi-commit push or a merged pull
# request still counts. The highest keyword wins:
#   #major              -> vX+1.0.0
#   #minor              -> vX.Y+1.0
#   #patch / no keyword -> vX.Y.Z+1
# The first release is always v1.0.0, whatever its commits say.
#
# Injected by the Cloudflare Landing Zone Release Manager. Change it in
# templates/module there, not in a module repository.
set -euo pipefail

semver='^v[0-9]+\.[0-9]+\.[0-9]+$'

# A re-run of a green push must not stack a second tag on the same commit.
if git tag --points-at HEAD | grep -qE "$semver"; then
  echo "HEAD is already tagged; nothing to do." >&2
  exit 0
fi

# Strict vX.Y.Z only, so a hand-made tag such as v2-rc can never become the base.
latest="$(git tag --list 'v*' --sort=-v:refname | grep -E "$semver" | head -n1 || true)"

if [[ -z "$latest" ]]; then
  echo "No previous release tag; first release." >&2
  echo "v1.0.0"
  exit 0
fi

messages="$(git log --format=%B "${latest}..HEAD")"

# The keyword must stand alone, so '#majority' or 'PR #minor-fix' do not match.
has_keyword() {
  grep -qiE "(^|[^[:alnum:]_#])#$1([^[:alnum:]_-]|$)" <<<"$messages"
}

IFS='.' read -r major minor patch <<<"${latest#v}"

if has_keyword major; then
  bump=major
  next="v$((major + 1)).0.0"
elif has_keyword minor; then
  bump=minor
  next="v${major}.$((minor + 1)).0"
else
  bump=patch
  next="v${major}.${minor}.$((patch + 1))"
fi

echo "latest: ${latest} bump: ${bump} next: ${next}" >&2
echo "$next"
