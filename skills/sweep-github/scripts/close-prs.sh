#!/usr/bin/env bash
# Close the PRs an assessment marked CLOSE. Dry run by default: prints, per PR,
# its state, any comment or review by a skipped author ($SWEEP_SKIP_AUTHORS),
# and the state of the PR it names as canonical. Re-run with --apply to close
# each one with a comment carrying the evidence.
#
#   close-prs.sh assessed.json            # check only
#   close-prs.sh assessed.json --apply    # close
#
# assessed.json is an array of the objects assess-brief.md asks agents for
# ({pr, verdict, close_reason, evidence, canonical, ...}).
#
# Env: REPO (owner/repo; defaults to the current checkout's repo),
#      SWEEP_SKIP_AUTHORS (space-separated GitHub logins).
set -euo pipefail

file="${1:?usage: close-prs.sh <assessed.json> [--apply]}"
apply="${2:-}"
repo="${REPO:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"
read -r -a skipped <<<"${SWEEP_SKIP_AUTHORS:-}"
humans=$(printf '%s\n' "${skipped[@]+"${skipped[@]}"}" | jq -R 'select(length > 0)' | jq -s .)

jq -c '.[] | select(.verdict == "CLOSE")' "$file" | while read -r row; do
  n=$(jq -r .pr <<<"$row")
  canon=$(jq -r '.canonical // empty' <<<"$row")
  info=$(gh pr view "$n" -R "$repo" --json state,comments,reviews | jq -r \
    --argjson h "$humans" \
    '"\(.state) skipped-authors=[\([.comments[], .reviews[] | .author.login | select(. as $a | $h | index($a))] | unique | join(","))]"')
  canon_state='-'
  [ -n "$canon" ] && canon_state=$(gh pr view "$canon" -R "$repo" --json state --jq .state)
  echo "#$n $info canonical=${canon:--}:$canon_state"

  if [ "$apply" = "--apply" ]; then
    why=$(jq -r .close_reason <<<"$row")
    ev=$(jq -r .evidence <<<"$row")
    gh pr close "$n" -R "$repo" \
      --comment "Closing in a PR sweep (${why}). ${ev} Reopen if this still carries something main lacks." >/dev/null
    echo "  closed"
  fi
done
