#!/usr/bin/env bash
# Tests for resolve-review-area.sh — the resolver that decides which
# codebase-review area(s) are DUE on a given run.
#
# The resolver is adaptive: for each area it reads GitHub state (the most
# recent `review(<area>):` issues/PRs and whether a review PR has merged)
# via `gh`, then picks an interval from a three-tier cadence:
#
#   fast    — a review PR merged recently, nothing open      (wk: 7d / daily: 1d after merge)
#   slow    — merged within 60d but latest review unmerged   (wk: 30d / daily: 7d after last review)
#   dormant — no merge in 60d (or never merged)              (wk: 90d / daily: 30d floor)
#
# `gh` is an EXTERNAL boundary (the GitHub API), so we stub it on PATH and
# feed canned issue/PR JSON. "Now" is injected via NOW_EPOCH_SECONDS so the
# tier math is deterministic. Dates go through jq (not GNU `date -d`) so
# the suite runs on Linux and macOS alike.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET_SCRIPT="${SCRIPT_DIR}/resolve-review-area.sh"

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

# ─── Fixed clock + helpers ───────────────────────────────────────────────
NOW=$(jq -rn '"2026-06-04T12:00:00Z" | fromdateiso8601')
NOW_ISO=$(jq -rn --argjson s "${NOW}" '$s | todateiso8601')

# Epoch seconds for "N days ago".
days_ago() { echo $((NOW - $1 * 86400)); }
# ISO timestamp from epoch seconds.
iso() { jq -rn --argjson s "$1" '$s | todateiso8601'; }

# Keep in sync with DAILY_AREAS + WEEKLY_AREAS in resolve-review-area.sh.
# (Same hand-sync contract the workflow_dispatch `options:` list already has.)
DAILY_AREAS=(billing-integrity e-commerce)
WEEKLY_AREAS=(
  ai-compliance architecture code-quality compliance correctness
  dependency-health documentation error-handling infrastructure
  performance-client performance-server privacy resilience scalability security testing
)
ALL_AREAS=("${DAILY_AREAS[@]}" "${WEEKLY_AREAS[@]}")

issue_obj() { # number area created_iso
  printf '{"number":%s,"title":"review(%s): findings — x","createdAt":"%s"}' "$1" "$2" "$3"
}

pr_obj() { # number area created_iso mergedAt_iso_or_null state
  local merged
  if [[ "$4" == "null" ]]; then merged="null"; else merged="\"$4\""; fi
  printf '{"number":%s,"title":"review(%s): weekly codebase review fixes","createdAt":"%s","mergedAt":%s,"state":"%s"}' \
    "$1" "$2" "$3" "${merged}" "$5"
}

json_array() { # obj...  -> "[obj,obj,...]"
  local IFS=,
  echo "[$*]"
}

# Issue objects for every area EXCEPT the target, each created "now" so
# they are never due — this isolates the target area under test.
baseline_issues_except() { # target
  local target="$1" n=900 out=()
  local a
  for a in "${ALL_AREAS[@]}"; do
    [[ "$a" == "${target}" ]] && continue
    out+=("$(issue_obj "${n}" "$a" "${NOW_ISO}")")
    n=$((n + 1))
  done
  local IFS=,
  echo "${out[*]}"
}

# Stub `gh` on PATH: cats the canned JSON the resolver asks for.
STUB_DIR=$(mktemp -d)
cat > "${STUB_DIR}/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "issue list") cat "${FAKE_ISSUES_JSON}" ;;
  "pr list")    cat "${FAKE_PRS_JSON}" ;;
  *) echo "[]" ;;
esac
STUB
chmod +x "${STUB_DIR}/gh"

# Run the resolver and echo the resolved areas_json line.
# Usage: run_resolver <event> <issues_json> <prs_json> [input_area]
run_resolver() {
  local event="$1" issues="$2" prs="$3" input_area="${4:-}"
  local out f_issues f_prs
  out=$(mktemp); f_issues=$(mktemp); f_prs=$(mktemp)
  printf '%s' "${issues}" > "${f_issues}"
  printf '%s' "${prs}" > "${f_prs}"

  PATH="${STUB_DIR}:${PATH}" \
  FAKE_ISSUES_JSON="${f_issues}" FAKE_PRS_JSON="${f_prs}" \
  GITHUB_OUTPUT="${out}" EVENT_NAME="${event}" REPO="owner/repo" \
  INPUT_REVIEW_AREA="${input_area}" NOW_EPOCH_SECONDS="${NOW}" \
    bash "${TARGET_SCRIPT}" >/dev/null 2>&1

  grep '^areas_json=' "${out}" | tail -n1 | sed 's/^areas_json=//'
  rm -f "${out}" "${f_issues}" "${f_prs}"
}

# Convenience: does the resolved JSON contain the area?
contains_area() { # areas_json area
  echo "$1" | jq -e --arg a "$2" 'index($a) != null' >/dev/null 2>&1 && echo "yes" || echo "no"
}

# ─── Tests ────────────────────────────────────────────────────────────────

# FAST: a review PR merged 8 days ago (> 7d weekly fast interval), nothing
# open → a fresh review is due.
test_fast_due_after_merge() {
  echo "test_fast_due_after_merge"
  local issues prs got
  issues=$(json_array "$(baseline_issues_except ai-compliance)" "$(issue_obj 1 ai-compliance "$(iso "$(days_ago 8)")")")
  prs=$(json_array "$(pr_obj 2 ai-compliance "$(iso "$(days_ago 10)")" "$(iso "$(days_ago 8)")" MERGED)")
  got=$(run_resolver schedule "${issues}" "${prs}")
  assert_eq "ai-compliance due 8d after merge" "yes" "$(contains_area "${got}" ai-compliance)"
}

# FAST not yet: merged only 3 days ago (< 7d) → not due.
test_fast_not_due_yet() {
  echo "test_fast_not_due_yet"
  local issues prs got
  issues=$(json_array "$(baseline_issues_except ai-compliance)" "$(issue_obj 1 ai-compliance "$(iso "$(days_ago 5)")")")
  prs=$(json_array "$(pr_obj 2 ai-compliance "$(iso "$(days_ago 5)")" "$(iso "$(days_ago 3)")" MERGED)")
  got=$(run_resolver schedule "${issues}" "${prs}")
  assert_eq "ai-compliance not due 3d after merge" "[]" "${got}"
}

# SLOW: merged 40d ago (engaged) but the latest review PR is OPEN/unmerged
# and was created 31d ago (> 30d slow interval) → fresh monthly review due.
test_slow_due_when_unmerged() {
  echo "test_slow_due_when_unmerged"
  local issues prs got
  issues=$(json_array "$(baseline_issues_except security)" "$(issue_obj 1 security "$(iso "$(days_ago 31)")")")
  prs=$(json_array \
    "$(pr_obj 2 security "$(iso "$(days_ago 50)")" "$(iso "$(days_ago 40)")" MERGED)" \
    "$(pr_obj 3 security "$(iso "$(days_ago 31)")" null OPEN)")
  got=$(run_resolver schedule "${issues}" "${prs}")
  assert_eq "security due 31d after unmerged review" "yes" "$(contains_area "${got}" security)"
}

# SLOW not yet: unmerged review only 10d old (< 30d) → not due.
test_slow_not_due_yet() {
  echo "test_slow_not_due_yet"
  local issues prs got
  issues=$(json_array "$(baseline_issues_except security)" "$(issue_obj 1 security "$(iso "$(days_ago 10)")")")
  prs=$(json_array \
    "$(pr_obj 2 security "$(iso "$(days_ago 50)")" "$(iso "$(days_ago 40)")" MERGED)" \
    "$(pr_obj 3 security "$(iso "$(days_ago 10)")" null OPEN)")
  got=$(run_resolver schedule "${issues}" "${prs}")
  assert_eq "security not due 10d after unmerged review" "[]" "${got}"
}

# DORMANT: never merged, last review 100d ago (> 90d quarterly floor) → due.
test_dormant_due_at_quarterly_floor() {
  echo "test_dormant_due_at_quarterly_floor"
  local issues prs got
  issues=$(json_array "$(baseline_issues_except privacy)" "$(issue_obj 1 privacy "$(iso "$(days_ago 100)")")")
  prs="[]"
  got=$(run_resolver schedule "${issues}" "${prs}")
  assert_eq "privacy due 100d after last review (never merged)" "yes" "$(contains_area "${got}" privacy)"
}

# DORMANT not yet: no merge in 60d, last review 31d ago → 90d floor not hit.
# (Contrast with e-commerce below, which DOES fire at 31d due to tighter floor.)
test_dormant_weekly_not_due_at_31d() {
  echo "test_dormant_weekly_not_due_at_31d"
  local issues prs got
  issues=$(json_array "$(baseline_issues_except privacy)" "$(issue_obj 1 privacy "$(iso "$(days_ago 31)")")")
  prs=$(json_array "$(pr_obj 2 privacy "$(iso "$(days_ago 80)")" "$(iso "$(days_ago 70)")" MERGED)")
  got=$(run_resolver schedule "${issues}" "${prs}")
  assert_eq "privacy not due 31d in (90d weekly floor)" "[]" "${got}"
}

# E-COMMERCE tighter floor: dormant (merge 70d ago), last review 31d ago →
# due, because the daily-area floor is 30d, not 90d.
test_ecommerce_monthly_floor_due_at_31d() {
  echo "test_ecommerce_monthly_floor_due_at_31d"
  local issues prs got
  issues=$(json_array "$(baseline_issues_except e-commerce)" "$(issue_obj 1 e-commerce "$(iso "$(days_ago 31)")")")
  prs=$(json_array "$(pr_obj 2 e-commerce "$(iso "$(days_ago 80)")" "$(iso "$(days_ago 70)")" MERGED)")
  got=$(run_resolver schedule "${issues}" "${prs}")
  assert_eq "e-commerce due 31d in (30d floor)" "yes" "$(contains_area "${got}" e-commerce)"
}

# BILLING-INTEGRITY tighter floor: like e-commerce, it is revenue-critical and
# lives in DAILY_AREAS, so its dormant floor is 30d (monthly), not 90d. Dormant
# (merge 70d ago), last review 31d ago → due.
test_billing_integrity_monthly_floor_due_at_31d() {
  echo "test_billing_integrity_monthly_floor_due_at_31d"
  local issues prs got
  issues=$(json_array "$(baseline_issues_except billing-integrity)" "$(issue_obj 1 billing-integrity "$(iso "$(days_ago 31)")")")
  prs=$(json_array "$(pr_obj 2 billing-integrity "$(iso "$(days_ago 80)")" "$(iso "$(days_ago 70)")" MERGED)")
  got=$(run_resolver schedule "${issues}" "${prs}")
  assert_eq "billing-integrity due 31d in (30d floor)" "yes" "$(contains_area "${got}" billing-integrity)"
}

# E-COMMERCE fast: merged 2d ago (> 1d daily fast), nothing open → due.
test_ecommerce_fast_due_after_merge() {
  echo "test_ecommerce_fast_due_after_merge"
  local issues prs got
  issues=$(json_array "$(baseline_issues_except e-commerce)" "$(issue_obj 1 e-commerce "$(iso "$(days_ago 4)")")")
  prs=$(json_array "$(pr_obj 2 e-commerce "$(iso "$(days_ago 4)")" "$(iso "$(days_ago 2)")" MERGED)")
  got=$(run_resolver schedule "${issues}" "${prs}")
  assert_eq "e-commerce due 2d after merge" "yes" "$(contains_area "${got}" e-commerce)"
}

# E-COMMERCE fast not yet: merged a few hours ago → not due.
test_ecommerce_fast_not_due_same_day() {
  echo "test_ecommerce_fast_not_due_same_day"
  local issues prs got merged_iso
  merged_iso=$(iso $((NOW - 3600)))  # 1h ago
  issues=$(json_array "$(baseline_issues_except e-commerce)" "$(issue_obj 1 e-commerce "${merged_iso}")")
  prs=$(json_array "$(pr_obj 2 e-commerce "${merged_iso}" "${merged_iso}" MERGED)")
  got=$(run_resolver schedule "${issues}" "${prs}")
  assert_eq "e-commerce not due 1h after merge" "[]" "${got}"
}

# BOOTSTRAP: an area never reviewed (no issues/PRs at all for it) is due.
test_bootstrap_area_is_due() {
  echo "test_bootstrap_area_is_due"
  local issues prs got
  # Only baseline for everything except testing; `testing` has no history.
  issues=$(json_array "$(baseline_issues_except testing)")
  prs="[]"
  got=$(run_resolver schedule "${issues}" "${prs}")
  assert_eq "testing due when never reviewed" "yes" "$(contains_area "${got}" testing)"
}

# A bootstrapping area is the ONLY one emitted when every other area is fresh.
test_bootstrap_emits_only_that_area() {
  echo "test_bootstrap_emits_only_that_area"
  local issues got
  issues=$(json_array "$(baseline_issues_except scalability)")
  got=$(run_resolver schedule "${issues}" "[]")
  assert_eq "only scalability due when it alone was never reviewed" '["scalability"]' "${got}"
}

# Every area in the resolver has a review prompt, and every prompt is an area.
test_prompts_match_areas() {
  echo "test_prompts_match_areas"
  local prompts_dir areas prompts
  prompts_dir="${SCRIPT_DIR}/../../review-prompts"
  areas=$(printf '%s\n' "${ALL_AREAS[@]}" | LC_ALL=C sort | tr '\n' ' ')
  prompts=$(find "${prompts_dir}" -maxdepth 1 -name '*.md' -exec basename {} .md \; | LC_ALL=C sort | tr '\n' ' ')
  assert_eq "review-prompts/*.md == resolver areas" "${areas}" "${prompts}"
}

# The workflow_dispatch options list matches the resolver's areas (plus "all").
test_dispatch_options_match_areas() {
  echo "test_dispatch_options_match_areas"
  local wf areas opts
  wf="${SCRIPT_DIR}/../codebase-review.yml"
  areas=$(printf '%s\n' all "${ALL_AREAS[@]}" | LC_ALL=C sort | tr '\n' ' ')
  opts=$(awk '/^ *options: *$/{f=1;next} f&&/^ *- /{print $2;next} f{exit}' "${wf}" | LC_ALL=C sort | tr '\n' ' ')
  assert_eq "codebase-review.yml options == resolver areas + all" "${areas}" "${opts}"
}

# workflow_dispatch with a single area passes it straight through.
test_dispatch_single_area() {
  echo "test_dispatch_single_area"
  local got
  got=$(run_resolver workflow_dispatch "[]" "[]" privacy)
  assert_eq "dispatch privacy" '["privacy"]' "${got}"
}

# workflow_dispatch "all" emits the full sorted area list.
test_dispatch_all_areas() {
  echo "test_dispatch_all_areas"
  local got len has_ecomm has_security
  got=$(run_resolver workflow_dispatch "[]" "[]" all)
  len=$(echo "${got}" | jq 'length')
  has_ecomm=$(contains_area "${got}" e-commerce)
  has_security=$(contains_area "${got}" security)
  assert_eq "dispatch all length" "${#ALL_AREAS[@]}" "${len}"
  assert_eq "dispatch all has e-commerce" "yes" "${has_ecomm}"
  assert_eq "dispatch all has security" "yes" "${has_security}"
}

# pull_request always emits exactly one area to exercise the pipeline.
test_pull_request_emits_one_area() {
  echo "test_pull_request_emits_one_area"
  local got len
  got=$(run_resolver pull_request "[]" "[]")
  len=$(echo "${got}" | jq 'length')
  assert_eq "pull_request emits single area" "1" "${len}"
}

# ─── Run ────────────────────────────────────────────────────────────────
test_fast_due_after_merge
test_fast_not_due_yet
test_slow_due_when_unmerged
test_slow_not_due_yet
test_dormant_due_at_quarterly_floor
test_dormant_weekly_not_due_at_31d
test_ecommerce_monthly_floor_due_at_31d
test_billing_integrity_monthly_floor_due_at_31d
test_ecommerce_fast_due_after_merge
test_ecommerce_fast_not_due_same_day
test_bootstrap_area_is_due
test_bootstrap_emits_only_that_area
test_prompts_match_areas
test_dispatch_options_match_areas
test_dispatch_single_area
test_dispatch_all_areas
test_pull_request_emits_one_area

rm -rf "${STUB_DIR}"

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
