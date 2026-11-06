#!/usr/bin/env bash
# Tests for detect-workflow-validation-skip.sh — the pre-flight that spots
# the one case where the Claude GitHub App refuses to run the agent: a PR
# that edits the very workflow file invoking it.
#
# Each test stands up a tiny repo with a default branch and a PR-side
# checkout, then asserts the script's `will-skip` output and whether it
# wrote the explanatory report.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET_SCRIPT="${SCRIPT_DIR}/detect-workflow-validation-skip.sh"

PASS=0
FAIL=0
FAILED_TESTS=()

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then
    PASS=$((PASS + 1))
    echo "  ✓ ${label}"
  else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("${label}")
    echo "  ✗ ${label}"
    echo "    expected: ${expected}"
    echo "    actual:   ${actual}"
  fi
}

WORKFLOW_FILE='.github/workflows/ai-qa-review.yml'

fixture_fatal() {
  echo "FATAL: fixture setup failed — $1" >&2
  exit 2
}

# Build a repo whose `origin/main` holds the baseline workflow file, with
# the working tree standing in for the PR checkout.
#
# $1 = 'edit-workflow' to make the PR modify that workflow file.
setup_fixture() {
  local mode="$1" d
  d=$(mktemp -d -t wfskip-XXXXXX)

  git init --quiet --bare "${d}/remote.git"
  git -C "${d}/remote.git" symbolic-ref HEAD refs/heads/main
  git init --quiet "${d}/work"
  (
    set -e
    cd "${d}/work"
    git symbolic-ref HEAD refs/heads/main
    mkdir -p "$(dirname "${WORKFLOW_FILE}")"
    printf 'name: AI QA Review\non: pull_request\n' > "${WORKFLOW_FILE}"
    git add -A
    git commit --quiet -m 'baseline workflow'
    git remote add origin "file://${d}/remote.git"
    git push --quiet origin main
  ) || fixture_fatal "could not seed the remote"

  if [[ "${mode}" == 'edit-workflow' ]]; then
    printf 'name: AI QA Review\non: pull_request\n# PR edits this file\n' \
      > "${d}/work/${WORKFLOW_FILE}"
  fi

  mkdir -p "${d}/artifacts"
  jq -n '{ repository: { default_branch: "main" },
           pull_request: { number: 42, base: { repo: { default_branch: "main" } } } }' \
    > "${d}/event.json"

  echo "${d}"
}

# Run the detector against a fixture; echo the `will-skip` output value.
run_detector() {
  local d="$1" out
  out="${d}/step-output"
  : > "${out}"
  (
    cd "${d}/work" || exit 1
    GITHUB_OUTPUT="${out}" \
      GITHUB_EVENT_PATH="${d}/event.json" \
      ARTIFACTS_DIR="${d}/artifacts" \
      WORKFLOW_FILE="${WORKFLOW_FILE}" \
      RUN_URL='https://github.com/example-org/example-repo/actions/runs/1' \
      bash "${TARGET_SCRIPT}"
  ) >/dev/null 2>&1
  sed -n 's/^will-skip=//p' "${out}"
}

report_body() {
  cat "$1/artifacts/_comment.md" 2>/dev/null
}

# --- Tests ----------------------------------------------------------------

# The case this exists for: a PR edits ai-qa-review.yml, so the App
# declines to run the agent and the job would otherwise die at the verify
# gate with no explanation.
test_detects_skip_when_pr_edits_the_workflow() {
  echo "test_detects_skip_when_pr_edits_the_workflow"
  local d
  d=$(setup_fixture edit-workflow) || exit 2
  assert_eq "will-skip is true" "true" "$(run_detector "${d}")"

  local body
  body=$(report_body "${d}")
  if [[ "${body}" == *'ai-qa-review'* && "${body}" == *'AI_QA_BLOCKING:NO'* ]]; then
    assert_eq "report explains the skip" "yes" "yes"
  else
    assert_eq "report explains the skip" "yes" "no: ${body}"
  fi
  rm -rf "${d}"
}

# The verify gate fails any report containing the "could not run" heading.
# This one is a deliberate, benign skip — it must not trip that wire.
test_report_does_not_trip_the_could_not_run_gate() {
  echo "test_report_does_not_trip_the_could_not_run_gate"
  local d
  d=$(setup_fixture edit-workflow) || exit 2
  run_detector "${d}" >/dev/null
  local rc=0
  ARTIFACTS_DIR="${d}/artifacts" bash "${SCRIPT_DIR}/verify-qa-report.sh" >/dev/null 2>&1 || rc=$?
  assert_eq "verify-qa-report.sh accepts the report" "0" "${rc}"
  rm -rf "${d}"
}

# The overwhelmingly common case: the PR leaves the workflow file alone, so
# the agent will run normally and we must not short-circuit it.
test_no_skip_when_workflow_is_untouched() {
  echo "test_no_skip_when_workflow_is_untouched"
  local d
  d=$(setup_fixture keep-workflow) || exit 2
  assert_eq "will-skip is false" "false" "$(run_detector "${d}")"
  assert_eq "no report written" "" "$(report_body "${d}")"
  rm -rf "${d}"
}

# Uncertainty must never cost us a QA pass: if the baseline can't be
# resolved, assume the agent will run.
test_no_skip_when_baseline_cannot_be_resolved() {
  echo "test_no_skip_when_baseline_cannot_be_resolved"
  local d
  d=$(setup_fixture keep-workflow) || exit 2
  git -C "${d}/work" remote set-url origin "file://${d}/nonexistent.git"
  assert_eq "will-skip is false" "false" "$(run_detector "${d}")"
  assert_eq "no report written" "" "$(report_body "${d}")"
  rm -rf "${d}"
}

# --- Run ------------------------------------------------------------------

test_detects_skip_when_pr_edits_the_workflow
test_report_does_not_trip_the_could_not_run_gate
test_no_skip_when_workflow_is_untouched
test_no_skip_when_baseline_cannot_be_resolved

echo
echo "Results: ${PASS} passed, ${FAIL} failed"
if (( FAIL > 0 )); then
  echo "Failed tests:"
  for t in "${FAILED_TESTS[@]}"; do
    echo "  - ${t}"
  done
  exit 1
fi
exit 0
