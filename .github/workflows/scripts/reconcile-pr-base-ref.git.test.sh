#!/usr/bin/env bash
# Integration test for reconcile-pr-base-ref.sh, reproducing the failure it
# exists to prevent — a stacked PR whose parent branch was deleted while
# the `qa` job was still waiting for its preview.
#
# Stands up a local bare repo as `origin`, opens a "stacked PR" against a
# parent branch, then deletes that parent branch (as GitHub does the moment
# the parent PR merges) while a frozen event payload still names it. Then
# runs the exact fetch claude-code-action's config restore runs:
#
#   git fetch origin <payload base.ref> --depth=1 --no-recurse-submodules
#
# Without the reconcile that fetch dies with `couldn't find remote ref`.
# With it, the fetch resolves against the default branch and the restore
# lands the reviewed CLAUDE.md.
#
# Run from anywhere:
#   bash .github/workflows/scripts/reconcile-pr-base-ref.git.test.sh

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

PARENT_BRANCH='feat/parent-branch'

# A fixture that cannot be built is a broken harness, not a failing test —
# abort the whole script rather than let the assertions below report on a
# world that was never set up. Exit 2 to distinguish it from test failures.
fixture_fatal() {
  echo "FATAL: fixture setup failed — $1" >&2
  exit 2
}

# Build: a bare "origin" holding `main` (with the reviewed CLAUDE.md) and a
# parent PR branch, plus a checkout of the stacked PR head carrying a
# hostile CLAUDE.md — the thing the restore is meant to throw away.
#
# $1 = 'delete-parent' to simulate the parent PR merging mid-run.
setup_fixture() {
  local mode="$1" d
  d=$(mktemp -d -t reconcile-git-XXXXXX)

  git init --quiet --bare "${d}/remote.git"
  # Pin the bare repo's HEAD rather than inheriting `init.defaultBranch`.
  # Without this the remote's HEAD dangles at `refs/heads/master` on any
  # machine that hasn't set that config (GitHub runners haven't), the clone
  # below reports "you appear to have cloned an empty repository", and every
  # subsequent fetch fails for a reason that has nothing to do with the bug
  # under test. Same reason we pin it on the seed repo.
  git -C "${d}/remote.git" symbolic-ref HEAD refs/heads/main
  git init --quiet "${d}/seed"
  (
    set -e
    cd "${d}/seed"
    git symbolic-ref HEAD refs/heads/main
    printf 'reviewed instructions\n' > CLAUDE.md
    git add CLAUDE.md
    git commit --quiet -m 'seed main'
    git branch "${PARENT_BRANCH}"
    git remote add origin "file://${d}/remote.git"
    git push --quiet origin main "${PARENT_BRANCH}"
  ) || fixture_fatal "could not seed the remote"

  git clone --quiet --depth=1 "file://${d}/remote.git" "${d}/work" \
    || fixture_fatal "could not clone the seeded remote"

  # Prove the fixture before any test leans on it: the clone must carry
  # main's reviewed CLAUDE.md. A silently-empty remote would otherwise make
  # every fetch fail, which reads as "bug reproduced" when it is really
  # "fixture broken" — the exact false green this guard exists to catch.
  if [[ "$(cat "${d}/work/CLAUDE.md" 2>/dev/null)" != 'reviewed instructions' ]]; then
    fixture_fatal "clone did not carry main's CLAUDE.md"
  fi

  printf 'hostile instructions\n' > "${d}/work/CLAUDE.md"

  if [[ "${mode}" == 'delete-parent' ]]; then
    git -C "${d}/seed" push --quiet origin --delete "${PARENT_BRANCH}"
  fi

  # The webhook payload as frozen when the PR was opened: base still names
  # the parent branch, whether or not that branch still exists.
  jq -n --arg base "${PARENT_BRANCH}" \
    '{
      repository: { default_branch: "main" },
      pull_request: {
        number: 42,
        head: { ref: "feat/child-branch" },
        base: { ref: $base, repo: { default_branch: "main" } }
      }
    }' > "${d}/event.json"

  echo "${d}"
}

# Replay claude-code-action's restore against the payload as it stands:
# fetch the recorded base ref, then check the trusted CLAUDE.md out of it.
# Echoes the fetch's exit code.
run_action_restore() {
  local d="$1" base rc=0
  base=$(jq -r '.pull_request.base.ref' "${d}/event.json")
  (
    cd "${d}/work" || exit 1
    git fetch origin "${base}" --depth=1 --no-recurse-submodules >/dev/null 2>&1 || exit $?
    git checkout "origin/${base}" -- CLAUDE.md >/dev/null 2>&1
  ) || rc=$?
  echo "${rc}"
}

reconcile() {
  GITHUB_EVENT_PATH="$1/event.json" bash "${TARGET_SCRIPT}" >/dev/null 2>&1
}

# --- Tests ----------------------------------------------------------------

# The bug, reproduced: the parent branch is gone, so the restore's fetch
# cannot resolve the ref the frozen payload names. This is the assertion
# that would go green again if the reconcile step were ever dropped.
test_restore_fails_without_reconcile_when_parent_branch_is_gone() {
  echo "test_restore_fails_without_reconcile_when_parent_branch_is_gone"
  local d
  d=$(setup_fixture delete-parent) || exit 2
  local rc
  rc=$(run_action_restore "${d}")
  if [[ "${rc}" == "0" ]]; then
    assert_eq "fetch of the deleted parent branch fails" "non-zero" "0"
  else
    assert_eq "fetch of the deleted parent branch fails" "non-zero" "non-zero"
  fi
  assert_eq "hostile CLAUDE.md was never replaced" "hostile instructions" \
    "$(cat "${d}/work/CLAUDE.md")"
  rm -rf "${d}"
}

# The fix: reconcile first, and the same restore succeeds against `main`
# and overwrites the PR-authored CLAUDE.md with the reviewed one.
test_restore_succeeds_after_reconcile_when_parent_branch_is_gone() {
  echo "test_restore_succeeds_after_reconcile_when_parent_branch_is_gone"
  local d
  d=$(setup_fixture delete-parent) || exit 2
  reconcile "${d}"
  assert_eq "fetch + checkout succeed" "0" "$(run_action_restore "${d}")"
  assert_eq "reviewed CLAUDE.md restored" "reviewed instructions" \
    "$(cat "${d}/work/CLAUDE.md")"
  rm -rf "${d}"
}

# A stacked PR whose parent branch is still alive would fetch fine, but it
# would restore "trusted" config from another unreviewed PR branch. After
# reconcile it restores from `main` instead — the race is closed rather
# than merely narrowed.
test_reconcile_prefers_default_branch_even_when_parent_branch_lives() {
  echo "test_reconcile_prefers_default_branch_even_when_parent_branch_lives"
  local d
  d=$(setup_fixture keep-parent) || exit 2
  reconcile "${d}"
  assert_eq "base ref repointed at main" "main" \
    "$(jq -r '.pull_request.base.ref' "${d}/event.json")"
  assert_eq "fetch + checkout succeed" "0" "$(run_action_restore "${d}")"
  assert_eq "reviewed CLAUDE.md restored" "reviewed instructions" \
    "$(cat "${d}/work/CLAUDE.md")"
  rm -rf "${d}"
}

# --- Run ------------------------------------------------------------------

test_restore_fails_without_reconcile_when_parent_branch_is_gone
test_restore_succeeds_after_reconcile_when_parent_branch_is_gone
test_reconcile_prefers_default_branch_even_when_parent_branch_lives

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
