#!/usr/bin/env bash
set -euo pipefail

# Trigger CI workflows on a given branch via workflow_dispatch.
#
# Required env vars:
#   GH_TOKEN
#   REPO - GitHub repository (owner/repo)
#   BRANCH - branch name to trigger on
#
# Optional env vars:
#   WORKFLOWS - space-separated list of workflow filenames (default: auto-detect)
#
# If WORKFLOWS is not set, this script will attempt to trigger common CI
# workflow names. Customize the WORKFLOWS variable for your project.

: "${REPO:?}" "${BRANCH:?}"

# Default: try common CI workflow names. Override with WORKFLOWS env var.
WORKFLOWS="${WORKFLOWS:-ci.yml checks.yml test.yml}"

echo "Triggering CI workflows on branch: ${BRANCH}"
for workflow in ${WORKFLOWS}; do
  echo "  -> ${workflow}"
  # stderr is left visible so a permissions or typo failure is diagnosable.
  gh workflow run "${workflow}" --ref "${BRANCH}" --repo "${REPO}" \
    || echo "::warning::Failed to trigger ${workflow} (not found, not dispatchable, or no permission)"
done
