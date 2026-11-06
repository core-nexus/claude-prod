#!/usr/bin/env bash
# Per PR: a line with size, how far behind the default branch, whether it merges
# cleanly and the CI rollup; the title beneath it; then which of its files the
# default branch has touched since the branch point.
# Cheap and read-only — run it before fanning out so the waves can be ordered
# and the conflict / drift cases flagged up front.
#
#   triage.sh 123 118 97
#
# Needs git >= 2.38 (for `git merge-tree --write-tree`) and an authenticated gh.
set -euo pipefail

if [[ $# -eq 0 ]]; then
  echo "usage: $0 <PR number>..." >&2
  exit 2
fi

base_branch="${BASE_BRANCH:-$(gh repo view --json defaultBranchRef --jq .defaultBranchRef.name)}"
git fetch -q origin "$base_branch"
for n in "$@"; do
  read -r branch add del draft title < <(gh pr view "$n" \
    --json headRefName,additions,deletions,isDraft,title \
    --jq '"\(.headRefName) \(.additions) \(.deletions) \(.isDraft) \(.title)"')
  git fetch -q origin "$branch"
  base=$(git merge-base "origin/$base_branch" "origin/$branch")
  behind=$(git rev-list --count "$base..origin/$base_branch")
  if git merge-tree --write-tree "origin/$base_branch" "origin/$branch" >/dev/null 2>&1; then
    merge=clean
  else
    merge=CONFLICT
  fi
  ci=$(gh pr view "$n" --json statusCheckRollup --jq \
    '[.statusCheckRollup[] | if (.conclusion // "") != "" then .conclusion else (.state // .status // "PENDING") end]
     | group_by(.) | map("\(.[0])=\(length)") | join(",")')
  printf '#%s %s +%s/-%s behind=%s merge=%s ci=[%s]%s\n    %s\n' \
    "$n" "$branch" "$add" "$del" "$behind" "$merge" "${ci:-none}" "$([ "$draft" = true ] && echo ' DRAFT')" "$title"
  git diff --name-only "$base" "origin/$branch" | while read -r f; do
    touched=$(git log -3 --format='%h %s' "$base..origin/$base_branch" -- "$f")
    if [ -n "$touched" ]; then
      printf '    %s touched %s:\n%s\n' "$base_branch" "$f" "$(sed 's/^/      /' <<<"$touched")"
    fi
  done
done
