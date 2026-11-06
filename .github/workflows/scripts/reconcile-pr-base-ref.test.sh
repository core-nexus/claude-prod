#!/usr/bin/env bash
# Tests for reconcile-pr-base-ref.sh — the step that repoints
# claude-code-action's trusted-config restore at the repository's default
# branch before the agent runs.
#
# The script's only observable effects are (a) its exit code and (b) the
# `.pull_request.base.ref` value in the event-payload file it is pointed at,
# so every test writes a fixture payload, runs the script against it, and
# asserts on both.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET_SCRIPT="${SCRIPT_DIR}/reconcile-pr-base-ref.sh"

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

FIXTURE=''

# Write a `pull_request` event payload with the given base ref and default
# branch. Mirrors the shape GitHub actually delivers: `repository` is the
# base repo, and `pull_request.base.repo` repeats it.
write_pr_payload() {
  local base_ref="$1" default_branch="$2"
  FIXTURE=$(mktemp -t reconcile-base-XXXXXX)
  jq -n \
    --arg base "${base_ref}" \
    --arg default "${default_branch}" \
    '{
      action: "opened",
      repository: { full_name: "example-org/example-repo", default_branch: $default },
      pull_request: {
        number: 42,
        head: { ref: "feat/child-branch" },
        base: { ref: $base, repo: { default_branch: $default } }
      }
    }' > "${FIXTURE}"
}

# Run the script against the current fixture; echo its exit code.
run_script() {
  local rc=0
  GITHUB_EVENT_PATH="${FIXTURE}" GITHUB_EVENT_NAME="${1:-pull_request}" \
    bash "${TARGET_SCRIPT}" >/dev/null 2>&1 || rc=$?
  echo "${rc}"
}

payload_base_ref() {
  jq -r '.pull_request.base.ref' "${FIXTURE}"
}

cleanup_fixture() {
  [[ -n "${FIXTURE}" ]] && rm -f "${FIXTURE}"
  FIXTURE=''
}

# --- Tests ----------------------------------------------------------------

# The reported failure: a PR was opened against a parent PR branch, the
# parent merged mid-run, and the branch was deleted out from under the
# frozen payload. Rewriting the base to the default branch removes the
# dependency on that ephemeral ref entirely.
test_rewrites_stacked_base_to_default_branch() {
  echo "test_rewrites_stacked_base_to_default_branch"
  write_pr_payload 'feat/parent-branch' 'main'
  assert_eq "exits 0" "0" "$(run_script)"
  assert_eq "base.ref rewritten to main" "main" "$(payload_base_ref)"
  cleanup_fixture
}

# The overwhelmingly common case: a PR already targeting the default branch
# must come out byte-identical, so the fix cannot regress normal PRs.
test_leaves_default_branch_base_untouched() {
  echo "test_leaves_default_branch_base_untouched"
  write_pr_payload 'main' 'main'
  local before
  before=$(cat "${FIXTURE}")
  assert_eq "exits 0" "0" "$(run_script)"
  assert_eq "base.ref unchanged" "main" "$(payload_base_ref)"
  assert_eq "payload byte-identical" "${before}" "$(cat "${FIXTURE}")"
  cleanup_fixture
}

# The default branch is read from the payload, not hardcoded — a repo whose
# default is `trunk` must reconcile to `trunk`.
test_honours_non_main_default_branch() {
  echo "test_honours_non_main_default_branch"
  write_pr_payload 'feat/stacked' 'trunk'
  assert_eq "exits 0" "0" "$(run_script)"
  assert_eq "base.ref rewritten to trunk" "trunk" "$(payload_base_ref)"
  cleanup_fixture
}

# Everything outside `.pull_request.base.ref` must survive the rewrite —
# claude-code-action reads the rest of the payload (PR number, head ref,
# repository) to do its job.
test_preserves_the_rest_of_the_payload() {
  echo "test_preserves_the_rest_of_the_payload"
  write_pr_payload 'feat/stacked' 'main'
  run_script >/dev/null
  assert_eq "pr number preserved" "42" "$(jq -r '.pull_request.number' "${FIXTURE}")"
  assert_eq "head ref preserved" "feat/child-branch" \
    "$(jq -r '.pull_request.head.ref' "${FIXTURE}")"
  assert_eq "repository preserved" "example-org/example-repo" \
    "$(jq -r '.repository.full_name' "${FIXTURE}")"
  cleanup_fixture
}

# `issue_comment` (`/qa-review`) payloads carry no `pull_request.base`;
# claude-code-action resolves the base live from the API on that path, so
# there is nothing to reconcile and nothing to fail on.
test_noop_when_payload_has_no_pull_request() {
  echo "test_noop_when_payload_has_no_pull_request"
  FIXTURE=$(mktemp -t reconcile-base-XXXXXX)
  jq -n '{ action: "created", issue: { number: 42 }, comment: { body: "/qa-review" } }' \
    > "${FIXTURE}"
  local before
  before=$(cat "${FIXTURE}")
  assert_eq "exits 0" "0" "$(run_script issue_comment)"
  assert_eq "payload byte-identical" "${before}" "$(cat "${FIXTURE}")"
  cleanup_fixture
}

# A payload without `default_branch` gives us nothing to reconcile *to*.
# Leave it alone rather than guessing a branch name: the action then behaves
# exactly as it does today.
test_noop_when_default_branch_is_absent() {
  echo "test_noop_when_default_branch_is_absent"
  FIXTURE=$(mktemp -t reconcile-base-XXXXXX)
  jq -n '{ pull_request: { number: 1, base: { ref: "feat/stacked" } } }' > "${FIXTURE}"
  assert_eq "exits 0" "0" "$(run_script)"
  assert_eq "base.ref unchanged" "feat/stacked" "$(payload_base_ref)"
  cleanup_fixture
}

# No event file at all (or an unreadable one) is not a reason to burn the
# job — the action will fail loudly on its own if it genuinely needs it.
test_noop_when_event_file_is_missing() {
  echo "test_noop_when_event_file_is_missing"
  local rc=0
  GITHUB_EVENT_PATH="/nonexistent/event.json" bash "${TARGET_SCRIPT}" >/dev/null 2>&1 || rc=$?
  assert_eq "exits 0" "0" "${rc}"
}

# A truncated / non-JSON payload must not leave a half-written file behind.
# We would rather hand the action the original bytes than a corrupted one.
test_leaves_malformed_payload_intact() {
  echo "test_leaves_malformed_payload_intact"
  FIXTURE=$(mktemp -t reconcile-base-XXXXXX)
  printf '{"pull_request": {"base": {"ref": "feat/stac' > "${FIXTURE}"
  local before
  before=$(cat "${FIXTURE}")
  assert_eq "exits 0" "0" "$(run_script)"
  assert_eq "payload byte-identical" "${before}" "$(cat "${FIXTURE}")"
  cleanup_fixture
}

# The rewrite must fail loudly rather than silently: if the reconciled base
# ref does not actually land in the payload, the action WILL die on
# `git fetch origin <stacked-branch>` minutes later, and a message naming
# both refs beats a bare git fatal there.
test_fails_loudly_when_payload_is_not_writable() {
  echo "test_fails_loudly_when_payload_is_not_writable"
  write_pr_payload 'feat/stacked' 'main'
  chmod 400 "${FIXTURE}"

  local rc=0 out
  out=$(GITHUB_EVENT_PATH="${FIXTURE}" bash "${TARGET_SCRIPT}" 2>&1) || rc=$?
  assert_eq "exits non-zero" "1" "${rc}"
  if [[ "${out}" == *"main"* && "${out}" == *"feat/stacked"* ]]; then
    assert_eq "error names both refs" "yes" "yes"
  else
    assert_eq "error names both refs" "yes" "no: ${out}"
  fi

  chmod 600 "${FIXTURE}"
  cleanup_fixture
}

# --- Run ------------------------------------------------------------------

test_rewrites_stacked_base_to_default_branch
test_leaves_default_branch_base_untouched
test_honours_non_main_default_branch
test_preserves_the_rest_of_the_payload
test_noop_when_payload_has_no_pull_request
test_noop_when_default_branch_is_absent
test_noop_when_event_file_is_missing
test_leaves_malformed_payload_intact
test_fails_loudly_when_payload_is_not_writable

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
