#!/usr/bin/env bash
# Tests for check-sentry-mcp-connected.sh — the sentry-triage gate that fails
# the job when Claude ran without a working Sentry MCP server.
#
# The script takes the claude-code-action execution file (a JSON array of SDK
# messages whose first entry is the `system`/`init` message carrying
# `mcp_servers[].status`) and exits 0 only when the `sentry` server reports
# `connected`. Tests write fixture transcripts and assert the exit code.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET_SCRIPT="${SCRIPT_DIR}/check-sentry-mcp-connected.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

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

# Write a transcript whose init message lists the given mcp_servers JSON, then
# run the check on it and print its exit code.
exit_code_for_servers() {
  local file="${TMP_DIR}/transcript.json"
  printf '[{"type":"system","subtype":"init","mcp_servers":%s},{"type":"result","subtype":"success","is_error":false}]' \
    "$1" >"${file}"
  bash "${TARGET_SCRIPT}" "${file}" >/dev/null 2>&1
  echo $?
}

test_connected_passes() {
  echo "test_connected_passes"
  assert_eq "sentry connected → 0" "0" \
    "$(exit_code_for_servers '[{"name":"sentry","status":"connected","source":"dynamic"}]')"
}

test_failed_fails() {
  echo "test_failed_fails"
  assert_eq "sentry failed → 1" "1" \
    "$(exit_code_for_servers '[{"name":"sentry","status":"failed","source":"dynamic"}]')"
}

test_missing_sentry_fails() {
  echo "test_missing_sentry_fails"
  assert_eq "no sentry server listed → 1" "1" \
    "$(exit_code_for_servers '[{"name":"github","status":"connected"}]')"
}

test_other_server_failing_still_passes() {
  echo "test_other_server_failing_still_passes"
  assert_eq "only sentry's status counts → 0" "0" \
    "$(exit_code_for_servers '[{"name":"github","status":"failed"},{"name":"sentry","status":"connected"}]')"
}

test_missing_file_fails() {
  echo "test_missing_file_fails"
  bash "${TARGET_SCRIPT}" "${TMP_DIR}/does-not-exist.json" >/dev/null 2>&1
  assert_eq "missing transcript → 1" "1" "$?"
}

test_no_init_message_fails() {
  echo "test_no_init_message_fails"
  local file="${TMP_DIR}/no-init.json"
  printf '[{"type":"result","subtype":"success"}]' >"${file}"
  bash "${TARGET_SCRIPT}" "${file}" >/dev/null 2>&1
  assert_eq "no init message → 1" "1" "$?"
}

test_connected_passes
test_failed_fails
test_missing_sentry_fails
test_other_server_failing_still_passes
test_missing_file_fails
test_no_init_message_fails

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
