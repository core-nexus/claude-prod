#!/usr/bin/env bash
# Tests for post-qa-comment.sh.
#
# Run from anywhere:
#   bash .github/workflows/scripts/post-qa-comment.test.sh
#
# The script is run end to end. The only stand-in is the `gh` CLI (the
# GitHub API boundary): a stub on PATH serves a canned comment list,
# records DELETEs, and captures the POSTed comment body so the tests can
# assert on exactly what would land on the PR.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET_SCRIPT="${SCRIPT_DIR}/post-qa-comment.sh"

PASS=0
FAIL=0
FAILED_TESTS=()

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then
    PASS=$((PASS + 1)); echo "  ✓ ${label}"
  else
    FAIL=$((FAIL + 1)); FAILED_TESTS+=("${label}")
    echo "  ✗ ${label}"; echo "    expected: ${expected}"; echo "    actual:   ${actual}"
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    PASS=$((PASS + 1)); echo "  ✓ ${label}"
  else
    FAIL=$((FAIL + 1)); FAILED_TESTS+=("${label}")
    echo "  ✗ ${label}"; echo "    expected to contain: ${needle}"; echo "    actual: ${haystack}"
  fi
}

assert_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" != *"${needle}"* ]]; then
    PASS=$((PASS + 1)); echo "  ✓ ${label}"
  else
    FAIL=$((FAIL + 1)); FAILED_TESTS+=("${label}")
    echo "  ✗ ${label}"; echo "    expected NOT to contain: ${needle}"; echo "    actual: ${haystack}"
  fi
}

# --- Fixture ----------------------------------------------------------------

# Builds a temp dir holding a `gh` stub and an artifacts dir. Echoes the dir.
setup_fixture() {
  local d
  d=$(mktemp -d -t post-qa-comment-XXXXXX)
  mkdir -p "${d}/bin" "${d}/artifacts"
  echo '[]' > "${d}/comments.json"
  cat > "${d}/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Minimal stand-in for `gh api`.
args="$*"
if [[ "${args}" == *"-X DELETE"* ]]; then
  echo "${args}" >> "${STUB_DIR}/deleted.log"
elif [[ "${args}" == *"-X POST"* ]]; then
  cat > "${STUB_DIR}/posted.json"
else
  cat "${STUB_DIR}/comments.json"
fi
STUB
  chmod +x "${d}/bin/gh"
  echo "${d}"
}

# Runs the script against a fixture; prints its exit code.
run_script() {
  local d="$1"; shift
  (
    export PATH="${d}/bin:${PATH}" STUB_DIR="${d}"
    export GH_TOKEN=x REPO=example-org/example-repo PR_NUMBER=7 RUN_ID=123
    export ARTIFACTS_DIR="${d}/artifacts" ARTIFACT_NAME=qa-artifacts-bundle
    for kv in "$@"; do export "${kv?}"; done
    bash "${TARGET_SCRIPT}" >/dev/null 2>&1
    echo $?
  )
}

posted_body() {
  jq -r '.body' "$1/posted.json" 2>/dev/null
}

write_report() {
  printf '%s\n' "$2" > "$1/artifacts/_comment.md"
}

# --- Tests ------------------------------------------------------------------

# A run that left no report checked nothing: the stand-in must not read as a
# pass, and the step must go red.
test_missing_report_posts_non_pass_and_fails() {
  echo "test_missing_report_posts_non_pass_and_fails"
  local d rc body
  d=$(setup_fixture)
  rc=$(run_script "${d}" QA_RESULT=failure)
  body=$(posted_body "${d}")
  assert_eq "exits non-zero" "1" "${rc}"
  assert_contains "fallback says blocking" "AI_QA_BLOCKING:YES" "${body}"
  assert_contains "fallback priority is UNKNOWN" "AI_QA_MAX_PRIORITY:UNKNOWN" "${body}"
  assert_not_contains "fallback never claims NONE" "AI_QA_MAX_PRIORITY:NONE" "${body}"
  rm -rf "${d}"
}

test_empty_report_posts_non_pass_and_fails() {
  echo "test_empty_report_posts_non_pass_and_fails"
  local d rc
  d=$(setup_fixture)
  : > "${d}/artifacts/_comment.md"
  rc=$(run_script "${d}")
  assert_eq "exits non-zero" "1" "${rc}"
  assert_contains "fallback priority is UNKNOWN" "AI_QA_MAX_PRIORITY:UNKNOWN" "$(posted_body "${d}")"
  rm -rf "${d}"
}

# A report cut off before its machine-readable tail fails closed: a human
# has to look, rather than the findings above being read as a pass.
test_missing_tail_fails_closed() {
  echo "test_missing_tail_fails_closed"
  local d rc body
  d=$(setup_fixture)
  write_report "${d}" $'<!-- ai-qa-review -->\n\n## AI QA Review\n\nFound a broken flow.'
  rc=$(run_script "${d}")
  body=$(posted_body "${d}")
  assert_eq "exits 0" "0" "${rc}"
  assert_contains "tail defaults to blocking" "AI_QA_BLOCKING:YES" "${body}"
  assert_contains "tail defaults to HIGH" "AI_QA_MAX_PRIORITY:HIGH" "${body}"
  rm -rf "${d}"
}

test_existing_tail_is_kept() {
  echo "test_existing_tail_is_kept"
  local d body
  d=$(setup_fixture)
  write_report "${d}" $'<!-- ai-qa-review -->\n\nAll clear.\n\nAI_QA_BLOCKING:NO\nAI_QA_MAX_PRIORITY:NONE'
  run_script "${d}" >/dev/null
  body=$(posted_body "${d}")
  assert_contains "agent's verdict kept" "AI_QA_MAX_PRIORITY:NONE" "${body}"
  assert_not_contains "no fail-closed tail added" "AI_QA_MAX_PRIORITY:HIGH" "${body}"
  rm -rf "${d}"
}

# An indented tail line still counts (e.g. inside a list or <details>).
test_indented_tail_is_recognised() {
  echo "test_indented_tail_is_recognised"
  local d
  d=$(setup_fixture)
  write_report "${d}" $'<!-- ai-qa-review -->\n\nAll clear.\n\n  AI_QA_BLOCKING:NO\n  AI_QA_MAX_PRIORITY:NONE'
  run_script "${d}" >/dev/null
  assert_not_contains "no fail-closed tail added" "AI_QA_MAX_PRIORITY:HIGH" "$(posted_body "${d}")"
  rm -rf "${d}"
}

test_marker_added_when_missing() {
  echo "test_marker_added_when_missing"
  local d
  d=$(setup_fixture)
  write_report "${d}" $'## AI QA Review\n\nAll clear.\n\nAI_QA_BLOCKING:NO\nAI_QA_MAX_PRIORITY:NONE'
  run_script "${d}" >/dev/null
  assert_eq "marker is the first line" "<!-- ai-qa-review -->" "$(posted_body "${d}" | head -1)"
  rm -rf "${d}"
}

# The agent sometimes references a screenshot it never saved to disk (it
# forgot `filename:`). That line is dropped, with a note, instead of
# rendering as a broken image.
test_reference_to_missing_file_is_stripped() {
  echo "test_reference_to_missing_file_is_stripped"
  local d body
  d=$(setup_fixture)
  : > "${d}/artifacts/01-present.png"
  write_report "${d}" $'<!-- ai-qa-review -->\n\n![ok](./qa-artifacts/01-present.png)\n![gone](./qa-artifacts/02-missing.png)\n\nAI_QA_BLOCKING:NO\nAI_QA_MAX_PRIORITY:NONE'
  run_script "${d}" >/dev/null
  body=$(posted_body "${d}")
  assert_not_contains "missing file's line removed" "02-missing.png" "${body}"
  assert_contains "present file still referenced" "01-present.png" "${body}"
  assert_contains "note explains the strip" "were stripped" "${body}"
  rm -rf "${d}"
}

test_media_base_url_rewrites_refs() {
  echo "test_media_base_url_rewrites_refs"
  local d body
  d=$(setup_fixture)
  : > "${d}/artifacts/01-shot.png"
  write_report "${d}" $'<!-- ai-qa-review -->\n\n![s](./qa-artifacts/01-shot.png)\n\nAI_QA_BLOCKING:NO\nAI_QA_MAX_PRIORITY:NONE'
  run_script "${d}" MEDIA_BASE_URL=https://media.example.com/run-123/ >/dev/null
  body=$(posted_body "${d}")
  assert_contains "ref rewritten to public host" "https://media.example.com/run-123/01-shot.png" "${body}"
  assert_not_contains "no relative ref left" "./qa-artifacts/" "${body}"
  rm -rf "${d}"
}

test_starting_ack_is_deleted() {
  echo "test_starting_ack_is_deleted"
  local d
  d=$(setup_fixture)
  printf '%s\n' '[{"id":555,"body":"<!-- ai-qa-review-starting -->\nstarting"},{"id":556,"body":"unrelated"}]' \
    > "${d}/comments.json"
  write_report "${d}" $'<!-- ai-qa-review -->\n\nAll clear.\n\nAI_QA_BLOCKING:NO\nAI_QA_MAX_PRIORITY:NONE'
  run_script "${d}" >/dev/null
  assert_contains "ack comment deleted" "issues/comments/555" "$(cat "${d}/deleted.log" 2>/dev/null)"
  assert_not_contains "other comment kept" "issues/comments/556" "$(cat "${d}/deleted.log" 2>/dev/null)"
  rm -rf "${d}"
}

# --- Run --------------------------------------------------------------------

test_missing_report_posts_non_pass_and_fails
test_empty_report_posts_non_pass_and_fails
test_missing_tail_fails_closed
test_existing_tail_is_kept
test_indented_tail_is_recognised
test_marker_added_when_missing
test_reference_to_missing_file_is_stripped
test_media_base_url_rewrites_refs
test_starting_ack_is_deleted

echo
echo "Results: ${PASS} passed, ${FAIL} failed"
if (( FAIL > 0 )); then
  printf '  - %s\n' "${FAILED_TESTS[@]}"
  exit 1
fi
