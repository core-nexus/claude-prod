#!/usr/bin/env bash
# List the open PRs a sweep covers: every open PR whose author is NOT in the
# skip list. Prints JSON (one array) with what triage needs.
#
#   scope.sh                     # skips the logins in $SWEEP_SKIP_AUTHORS (default: none)
#   scope.sh alice bob           # explicit skip list (overrides the env var)
#   scope.sh | jq -r '.[] | select(.isDraft | not) | .number'
#
# Env: REPO (owner/repo; defaults to the current checkout's repo),
#      SWEEP_SKIP_AUTHORS (space-separated GitHub logins).
set -euo pipefail

repo="${REPO:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"
if [ $# -gt 0 ]; then
  skipped=("$@")
else
  read -r -a skipped <<<"${SWEEP_SKIP_AUTHORS:-}"
fi
skip_json=$(printf '%s\n' "${skipped[@]+"${skipped[@]}"}" | jq -R 'select(length > 0)' | jq -s .)

gh pr list -R "$repo" --state open --limit 500 \
  --json number,title,author,isDraft,labels,createdAt,updatedAt,headRefName,mergeable,additions,deletions \
  | jq --argjson skip "$skip_json" \
    '[.[] | select(.author.login as $a | $skip | index($a) | not)] | sort_by(.number)'
