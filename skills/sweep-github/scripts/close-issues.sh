#!/usr/bin/env bash
# Close the issues an assessment marked CLOSE. Dry run by default: prints each
# issue's state, author and canonical. Re-run with --apply to close each one
# with a comment carrying the evidence.
#
# Author care is enforced here, not only in the brief: an issue by a skipped
# author ($SWEEP_SKIP_AUTHORS) is closed only as fixed, surface-gone or
# duplicate. Any other reason prints SKIP and leaves it open.
#
#   close-issues.sh assessed-issues.json            # check only
#   close-issues.sh assessed-issues.json --apply    # close
#
# Env: REPO (owner/repo; defaults to the current checkout's repo),
#      SWEEP_SKIP_AUTHORS (space-separated GitHub logins).
set -euo pipefail

file="${1:?usage: close-issues.sh <assessed-issues.json> [--apply]}"
apply="${2:-}"
repo="${REPO:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"
skipped=" ${SWEEP_SKIP_AUTHORS:-} "

jq -c '.[] | select(.verdict == "CLOSE")' "$file" | while read -r row; do
  n=$(jq -r .issue <<<"$row")
  why=$(jq -r .close_reason <<<"$row")
  read -r state author < <(gh issue view "$n" -R "$repo" --json state,author \
    --jq '"\(.state) \(.author.login)"')
  if [[ "$skipped" == *" $author "* ]] && [[ ! "$why" =~ ^(fixed|surface-gone|duplicate)$ ]]; then
    echo "#$n SKIP ($author, reason '$why' not allowed for their issues)"
    continue
  fi
  echo "#$n $state $author $why canonical=$(jq -r '.canonical // "-"' <<<"$row")"

  if [ "$apply" = "--apply" ] && [ "$state" = OPEN ]; then
    ev=$(jq -r .evidence <<<"$row")
    reason=completed
    [[ "$why" =~ ^(obsolete|not-actionable)$ ]] && reason='not planned'
    [ "$why" = duplicate ] && reason=duplicate
    gh issue close "$n" -R "$repo" --reason "$reason" \
      --comment "Closing in a PR/issue sweep (${why}). ${ev} Reopen if this is still live." >/dev/null
    echo "  closed"
  fi
done
