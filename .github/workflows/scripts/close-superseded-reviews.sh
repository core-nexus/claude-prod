#!/usr/bin/env bash
set -euo pipefail

# Close older auto-review issues and PRs for a given review area,
# keeping only the most recent one of each. Runs as a deterministic post-step
# of codebase-review.yml instead of asking the agent to do it, so superseded
# items are closed reliably even when the agent forgets or runs out of turns.
#
# Required env vars:
#   GH_TOKEN   - GitHub token with issues:write and pull-requests:write
#   REPO       - GitHub repository (owner/repo)
#   REVIEW_AREA - the review area name (e.g. "security", "privacy")
#
# A failed close is reported as a workflow warning (and does not abort the
# loop), so one stuck item cannot keep the rest open.

: "${REPO:?}" "${REVIEW_AREA:?}"

PREFIX="review(${REVIEW_AREA}):"

close_old_items() {
  local item_type="$1"  # "issue" or "pr"

  # Get all open items with auto-review label, then filter by prefix via jq --arg
  local raw_json
  if [[ "${item_type}" == "issue" ]]; then
    raw_json=$(gh issue list \
      --repo "${REPO}" \
      --label "auto-review" \
      --state open \
      --json number,title,createdAt)
  else
    raw_json=$(gh pr list \
      --repo "${REPO}" \
      --label "auto-review" \
      --state open \
      --json number,title,createdAt)
  fi

  local items
  items=$(echo "${raw_json}" | jq --arg prefix "${PREFIX}" \
    '[.[] | select(.title | startswith($prefix))] | sort_by(.createdAt) | reverse')

  local count
  count=$(echo "${items}" | jq 'length')
  echo "Found ${count} open ${item_type}(s) for ${PREFIX}"

  if [[ "${count}" -le 1 ]]; then
    echo "Nothing to close."
    return
  fi

  # Keep the newest (index 0), close the rest
  local newest_number
  newest_number=$(echo "${items}" | jq '.[0].number')
  echo "Keeping newest ${item_type}: #${newest_number}"

  local i=1
  while [[ ${i} -lt ${count} ]]; do
    local old_number
    old_number=$(echo "${items}" | jq ".[${i}].number")
    echo "Closing ${item_type} #${old_number} (superseded by #${newest_number})"

    if [[ "${item_type}" == "issue" ]]; then
      gh issue close "${old_number}" \
        --repo "${REPO}" \
        --comment "Superseded by #${newest_number}." \
        || echo "::warning::Failed to close issue #${old_number} (superseded by #${newest_number})"
    else
      gh pr close "${old_number}" \
        --repo "${REPO}" \
        --comment "Superseded by #${newest_number}." \
        || echo "::warning::Failed to close PR #${old_number} (superseded by #${newest_number})"
    fi

    i=$((i + 1))
  done
}

echo "=== Closing superseded review issues ==="
close_old_items "issue"

echo "=== Closing superseded review PRs ==="
close_old_items "pr"
