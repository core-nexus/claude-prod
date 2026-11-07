#!/usr/bin/env bash
# Spot, up front, the one case where the Claude GitHub App declines to run
# the agent at all — and turn it into an honest report instead of a
# mystifying red check.
#
# ── The condition ─────────────────────────────────────────────────────────
#
# The App validates the workflow file that invoked it against the copy on
# the repository's default branch, and refuses when they differ:
#
#   Skipping action due to workflow validation: Workflow validation failed.
#   The workflow file must exist and have identical content to the version
#   on the repository's default branch.
#
# That is an anti-tampering guard, and a correct one: without it a PR could
# rewrite the agent's own workflow and have the agent run under the rewrite.
# The consequence is that any PR editing `ai-qa-review.yml` gets its agent
# skipped. The action exits 0, writes no report, and our verify gate then
# fails the job for a reason that has nothing to do with the PR — the same
# "QA silently didn't run" failure mode the reconcile step exists to fix,
# arriving by a different road.
#
# The App exposes this as `skipped_due_to_workflow_validation_mismatch`, but
# that output is not declared in the composite action's `outputs:` block, so
# a workflow cannot read it. We reproduce the check instead: same rule, same
# answer, and we get it BEFORE spending twenty minutes waiting on a preview
# deploy we are not going to use.
#
# ── Contract ─────────────────────────────────────────────────────────────
#
# Required env:
#   WORKFLOW_FILE  - repo-relative path of the invoking workflow file.
#                    Passed explicitly rather than parsed out of
#                    GITHUB_WORKFLOW_REF: the caller always knows its own
#                    filename, and a literal beats a parser.
#   ARTIFACTS_DIR  - where to write the explanatory `_comment.md`.
#   GITHUB_EVENT_PATH, RUN_URL - default branch and a link for the report.
#
# Output: `will-skip=true|false` on $GITHUB_OUTPUT. On `true` it also writes
# `$ARTIFACTS_DIR/_comment.md` so the post-comment step publishes something a human
# can act on, and so the verify gate sees a real report.
#
# Uncertainty always resolves to `false`. A wrong `true` costs a QA pass; a
# wrong `false` costs a confusing red check. Those are not
# symmetric, so we only claim a skip when we can prove one.
#
# Tested by detect-workflow-validation-skip.test.sh.

set -uo pipefail

: "${WORKFLOW_FILE:?}"
: "${ARTIFACTS_DIR:?}"

emit() {
  echo "will-skip=$1" >> "${GITHUB_OUTPUT:-/dev/stdout}"
}

no_skip() {
  echo "$1"
  echo "Assuming the agent will run normally."
  emit false
  exit 0
}

DEFAULT_BRANCH="$(jq -r '
  .pull_request.base.repo.default_branch // .repository.default_branch // ""
' "${GITHUB_EVENT_PATH:-/dev/null}" 2>/dev/null)" || DEFAULT_BRANCH=''

if [[ -z "${DEFAULT_BRANCH}" ]]; then
  no_skip "Could not read the default branch from the event payload."
fi

# The checkout is shallow and single-branch, so the baseline has to be
# fetched before it can be read.
if ! git fetch origin "${DEFAULT_BRANCH}" --depth=1 --no-recurse-submodules >/dev/null 2>&1; then
  no_skip "Could not fetch origin/${DEFAULT_BRANCH} to compare the workflow file."
fi

BASELINE="$(git show "origin/${DEFAULT_BRANCH}:${WORKFLOW_FILE}" 2>/dev/null)" || BASELINE=''
if [[ -z "${BASELINE}" ]]; then
  # A workflow file absent from the default branch is a brand-new one. The
  # App skips those too, but "new workflow" is better served by the normal
  # path than by a report claiming this PR broke something.
  no_skip "${WORKFLOW_FILE} does not exist on origin/${DEFAULT_BRANCH}."
fi

if [[ "${BASELINE}" == "$(cat "${WORKFLOW_FILE}" 2>/dev/null)" ]]; then
  echo "${WORKFLOW_FILE} matches origin/${DEFAULT_BRANCH}; the agent will run normally."
  emit false
  exit 0
fi

echo "${WORKFLOW_FILE} differs from origin/${DEFAULT_BRANCH}."
echo "The Claude GitHub App will decline to run the agent on this PR."

mkdir -p "${ARTIFACTS_DIR}"

# Deliberately NOT the "— could not run" heading: that phrase is the verify
# gate's tripwire for a genuinely broken QA run, and this is a benign,
# expected, self-resolving skip. Keep the two signals distinct.
cat > "${ARTIFACTS_DIR}/_comment.md" <<REPORT
<!-- ai-qa-review -->

## 🤖 AI QA Review — skipped for this PR

This PR edits \`${WORKFLOW_FILE}\`, so the Claude GitHub App declined to
run the QA agent: it requires the invoking workflow file to match the copy
on \`${DEFAULT_BRANCH}\`. That guard is what stops a PR from rewriting the
agent's own workflow and then running under the rewrite.

Nothing is wrong with this PR, and nothing needs re-running — QA will run
normally on the next PR, once these workflow changes are on
\`${DEFAULT_BRANCH}\`.

**Worth knowing while reviewing:** any other Claude workflow this PR edits
(e.g. the code-review workflow) skips for the same reason, so this PR may
have had no automated review. It needs a human read.

See the [workflow run](${RUN_URL:-https://github.com}) for logs.

AI_QA_BLOCKING:NO
AI_QA_MAX_PRIORITY:NONE
REPORT

emit true
