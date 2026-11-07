#!/usr/bin/env bash
set -euo pipefail

# Commit the updated changelog to the working branch, push it, and open a PR.
# This script NEVER pushes to the base branch directly — every change lands via
# a reviewable pull request.
#
# Required env vars:
#   BRANCH        - the working branch to push (e.g. changelog/auto-YYYY-MM-DD)
#   GH_TOKEN      - token with permission to open pull requests
# Optional env vars:
#   CHANGELOG_FILE - path to the changelog (default: CHANGELOG.md)
#   BASE_BRANCH    - PR base branch (default: main)
#   EVENT_NAME     - trigger event name, used in the PR body (default: schedule)
#   CHANGELOG_AUTO_MERGE - "true" arms squash auto-merge on the new PR so it lands
#                    once required checks pass (default: false). The next run
#                    starts from the newest dated heading on the base branch, so
#                    an unmerged changelog PR makes it repeat these entries.

: "${BRANCH:?}" "${GH_TOKEN:?}"
CHANGELOG_FILE="${CHANGELOG_FILE:-CHANGELOG.md}"
BASE_BRANCH="${BASE_BRANCH:-main}"
EVENT_NAME="${EVENT_NAME:-schedule}"
CHANGELOG_AUTO_MERGE="${CHANGELOG_AUTO_MERGE:-false}"

DATE=$(date -u +%Y-%m-%d)
git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git add "${CHANGELOG_FILE}"
git commit -m "docs: update changelog through ${DATE}"
git push -u origin "${BRANCH}"

gh pr create \
  --title "docs: update changelog through ${DATE}" \
  --body "Automated changelog update (triggered by ${EVENT_NAME}). Review the generated entries before merging." \
  --base "${BASE_BRANCH}" \
  --head "${BRANCH}"

if [[ "${CHANGELOG_AUTO_MERGE}" == "true" ]]; then
  # Fails loudly if the repo has auto-merge disabled: the setting asked for it.
  gh pr merge "${BRANCH}" --auto --squash
fi
