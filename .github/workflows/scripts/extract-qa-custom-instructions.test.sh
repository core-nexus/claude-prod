#!/usr/bin/env bash
# Tests for extract-qa-custom-instructions.sh — the helper that pulls any
# custom instructions a user appended to a `/qa-review` PR comment so the
# AI QA workflow can fold them into the agent prompt.
#
# The script reads the comment body from $COMMENT_BODY (an env var, not
# stdin) and prints the extracted instructions to stdout. Empty output
# means "no custom instructions; run the default QA pass".

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET_SCRIPT="${SCRIPT_DIR}/extract-qa-custom-instructions.sh"

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
    echo "    expected: $(printf '%q' "${expected}")"
    echo "    actual:   $(printf '%q' "${actual}")"
  fi
}

run_extract() {
  COMMENT_BODY="$1" bash "${TARGET_SCRIPT}"
}

# --- Tests ----------------------------------------------------------------

test_empty_comment_body() {
  echo "test_empty_comment_body"
  local out
  out="$(run_extract '')"
  assert_eq "empty body → empty output" "" "${out}"
}

test_unset_comment_body() {
  echo "test_unset_comment_body"
  local out
  # Deliberately don't set COMMENT_BODY — script must default to empty.
  out="$(unset COMMENT_BODY; bash "${TARGET_SCRIPT}")"
  assert_eq "unset COMMENT_BODY → empty output" "" "${out}"
}

test_bare_command_no_instructions() {
  echo "test_bare_command_no_instructions"
  local out
  out="$(run_extract '/qa-review')"
  assert_eq "'/qa-review' alone → empty output" "" "${out}"
}

test_command_with_trailing_whitespace() {
  echo "test_command_with_trailing_whitespace"
  local out
  out="$(run_extract '/qa-review   ')"
  assert_eq "'/qa-review' + spaces → empty output" "" "${out}"
}

test_command_with_trailing_newlines() {
  echo "test_command_with_trailing_newlines"
  local out
  out="$(run_extract $'/qa-review\n\n')"
  assert_eq "'/qa-review' + newlines → empty output" "" "${out}"
}

test_single_line_instructions() {
  echo "test_single_line_instructions"
  local out
  out="$(run_extract '/qa-review focus on the login flow')"
  assert_eq "single-line instructions extracted verbatim" \
    "focus on the login flow" "${out}"
}

test_instructions_on_next_line() {
  echo "test_instructions_on_next_line"
  local body=$'/qa-review\nfocus on the login flow'
  local out
  out="$(run_extract "${body}")"
  assert_eq "newline-separated instructions extracted" \
    "focus on the login flow" "${out}"
}

test_multi_line_instructions_preserved() {
  echo "test_multi_line_instructions_preserved"
  local body=$'/qa-review please:\n- check the login flow\n- screenshot the admin page\n- verify dragdrop persists'
  local out
  out="$(run_extract "${body}")"
  local expected=$'please:\n- check the login flow\n- screenshot the admin page\n- verify dragdrop persists'
  assert_eq "multi-line body preserves internal newlines" \
    "${expected}" "${out}"
}

test_blank_lines_inside_instructions_preserved() {
  echo "test_blank_lines_inside_instructions_preserved"
  local body=$'/qa-review first paragraph\n\nsecond paragraph'
  local out
  out="$(run_extract "${body}")"
  local expected=$'first paragraph\n\nsecond paragraph'
  assert_eq "blank lines inside instructions preserved" \
    "${expected}" "${out}"
}

test_leading_text_before_command_ignored() {
  echo "test_leading_text_before_command_ignored"
  local body=$'Hey claude, please run\n/qa-review focus on the settings page'
  local out
  out="$(run_extract "${body}")"
  assert_eq "text before /qa-review is ignored" \
    "focus on the settings page" "${out}"
}

test_qa_reviewing_word_does_not_match() {
  echo "test_qa_reviewing_word_does_not_match"
  # /qa-reviewing is a longer word — must NOT trigger extraction at that
  # position. With no later real /qa-review token, output is empty.
  local out
  out="$(run_extract "I'm /qa-reviewing this PR")"
  assert_eq "/qa-reviewing alone → no extraction" "" "${out}"
}

test_qa_reviewing_then_real_command() {
  echo "test_qa_reviewing_then_real_command"
  # Should skip past /qa-reviewing and find the real /qa-review later.
  local body=$'/qa-reviewing this comment\n/qa-review focus on login'
  local out
  out="$(run_extract "${body}")"
  assert_eq "first /qa-reviewing skipped, real command used" \
    "focus on login" "${out}"
}

test_trailing_whitespace_in_instructions_preserved() {
  echo "test_trailing_whitespace_in_instructions_preserved"
  # We strip ONLY leading whitespace after /qa-review. Trailing whitespace
  # is part of the user's intent and stays. Asserted via file size because
  # bash `$(...)` strips trailing newlines — `od` would also work, but
  # byte-count is the simplest observable property here.
  local body=$'/qa-review focus on login\n'
  local tmp
  tmp="$(mktemp)"
  COMMENT_BODY="${body}" bash "${TARGET_SCRIPT}" > "${tmp}"
  local size
  # tr: BSD/macOS `wc` left-pads the count with spaces.
  size="$(wc -c < "${tmp}" | tr -d ' ')"
  rm -f "${tmp}"
  # "focus on login\n" = 16 bytes
  assert_eq "trailing newline preserved (16 bytes on disk)" "16" "${size}"
}

test_instructions_contain_dollar_signs_unchanged() {
  echo "test_instructions_contain_dollar_signs_unchanged"
  # Extraction must NOT expand env-var references in the user's text. The
  # single-quoted `$REPO` and `$HOME` below are intentional literal-text
  # fixtures, not variables to expand — hence the local SC2016 silencing.
  local out
  # shellcheck disable=SC2016
  out="$(run_extract '/qa-review please check $REPO and $HOME exposure')"
  # shellcheck disable=SC2016
  assert_eq "dollar-sign refs in instructions not expanded" \
    'please check $REPO and $HOME exposure' "${out}"
}

# --- Run all tests --------------------------------------------------------

test_empty_comment_body
test_unset_comment_body
test_bare_command_no_instructions
test_command_with_trailing_whitespace
test_command_with_trailing_newlines
test_single_line_instructions
test_instructions_on_next_line
test_multi_line_instructions_preserved
test_blank_lines_inside_instructions_preserved
test_leading_text_before_command_ignored
test_qa_reviewing_word_does_not_match
test_qa_reviewing_then_real_command
test_trailing_whitespace_in_instructions_preserved
test_instructions_contain_dollar_signs_unchanged

echo ""
echo "Passed: ${PASS}"
echo "Failed: ${FAIL}"
if [[ "${FAIL}" -gt 0 ]]; then
  echo "Failed tests:"
  for t in "${FAILED_TESTS[@]}"; do
    echo "  - ${t}"
  done
  exit 1
fi
