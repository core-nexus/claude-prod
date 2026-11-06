#!/usr/bin/env bash
# Give a PR or an issue exactly one Priority-N label: remove every other
# Priority-* label it carries, then add Priority-N. Idempotent. Uses the REST
# issues endpoints, which serve PRs and issues alike.
#
#   set-priority.sh 123 9
#
# Env: REPO (owner/repo; defaults to the current checkout's repo).
set -euo pipefail

n="${1:?usage: set-priority.sh <PR or issue number> <1-10>}"
p="${2:?usage: set-priority.sh <PR or issue number> <1-10>}"
[[ "$p" =~ ^([1-9]|10)$ ]] || { echo "priority must be 1-10, got $p" >&2; exit 1; }

repo="${REPO:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"
endpoint="repos/$repo/issues/$n/labels"
want="Priority-$p"
while read -r l; do
  [ -n "$l" ] && [ "$l" != "$want" ] && gh api -X DELETE "$endpoint/$l" >/dev/null
done < <(gh api "$endpoint" --jq '.[].name | select(test("^Priority-"))')

gh api -X POST "$endpoint" -f "labels[]=$want" >/dev/null
echo "#$n → $want"
