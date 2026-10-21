#!/usr/bin/env bash
# Written by `devkit sync` from DylKit. Change DylKit's copy, not this one.
# Usage: ci/github/pr-body.sh <merge-commit-sha> <out-file>
# Writes the body of the GitHub PR that produced the commit to <out-file>, for `release-kit version
# --pr-body-file`. When the lookup fails it leaves the file empty and release-kit falls back to the merge
# commit message. This is the only GitHub-specific release step.
set -uo pipefail

sha="$1"
out="$2"
: >"$out"

response="$(curl -fsSL --max-time 20 \
  -H "Authorization: Bearer ${GITHUB_TOKEN:?}" \
  -H "Accept: application/vnd.github+json" \
  "${GITHUB_API_URL:-https://api.github.com}/repos/${GITHUB_REPOSITORY:?}/commits/$sha/pulls")" || {
  echo "::warning::couldn't look up the PR for $sha; release-kit will read the merge commit message"
  exit 0
}

jq -r --arg sha "$sha" '(map(select(.merge_commit_sha == $sha)) + .)[0].body // empty' <<<"$response" >"$out" || : >"$out"
if [[ -s "$out" ]]; then
  echo "read the PR body for $sha"
else
  echo "::warning::no PR body for $sha; release-kit will read the merge commit message"
fi
