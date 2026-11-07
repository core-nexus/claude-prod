#!/usr/bin/env bash
#
# prepare-squash.sh <old-branch> <new-branch> [worktree-path]
#
# Stage the FULL net diff of <old-branch> as a single squash onto the latest
# default branch, on a fresh <new-branch> in its own git worktree. Stops
# WITHOUT committing so the caller can `git commit` with the pre-commit hooks
# enabled, which is the whole point of a PR reset.
#
# A worktree, not a checkout, because several agents and developers share this
# repo. Switching the primary checkout's branch out from under them is how work
# gets clobbered.
#
# Verifies nothing is lost by comparing FEATURE CONTRIBUTIONS, not whole trees:
# what the new branch adds over the latest default branch must equal what the
# old branch introduced over its merge base. That holds even when the default
# branch has advanced. If the newer default branch touched the same lines as
# the feature (a real conflict or re-contextualization), the two will not match
# and the script stops so you can review before committing.
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "usage: $0 <old-branch> <new-branch> [worktree-path]" >&2
  exit 2
fi
old_branch="$1"
new_branch="$2"

# The MAIN working tree, not `git rev-parse --show-toplevel`: this script is
# often run from inside a worktree, and --show-toplevel would return that
# worktree, nesting .claude/worktrees/ inside it. --git-common-dir is the main
# repo's .git even from inside a worktree, so its parent is the main tree.
#
# Deliberately no pipe here: under `set -o pipefail`, piping a long git listing
# into `head -1` makes git die of SIGPIPE and takes the whole script with it
# (exit 141).
repo_root="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"
# Branch names carry slashes; a worktree directory should not.
worktree_path="${3:-${repo_root}/.claude/worktrees/$(echo "${new_branch}" | tr '/' '-')}"

# No clean-tree check. The upstream version needed one because it ran
# `git checkout -b` in the current tree; this one builds the squash in a fresh
# worktree, so whatever the caller has staged, modified, or left untracked is
# untouched and irrelevant. Demanding a clean tree here only refuses to run
# over stray screenshots and scratch files.

if [[ -e "${worktree_path}" ]]; then
  echo "error: ${worktree_path} already exists (leftover from an aborted run?)." >&2
  echo "Remove it with 'git worktree remove ${worktree_path}' or pick another name." >&2
  exit 1
fi

base="$(gh repo view --json defaultBranchRef --jq .defaultBranchRef.name)"
if [[ -z "${base}" ]]; then
  echo "error: could not determine the default branch via gh." >&2
  exit 1
fi
echo "==> default branch is ${base}"

echo "==> fetching origin/${base} and origin/${old_branch}"
git fetch origin "${base}" "${old_branch}"

echo "==> creating ${new_branch} at ${worktree_path}, off the latest origin/${base}"
# -b (not -B): fail loudly if the branch already exists, e.g. a leftover from an
# aborted prior run, instead of silently clobbering it. Pick a fresh name.
git worktree add -b "${new_branch}" "${worktree_path}" "origin/${base}"

cd "${worktree_path}"

echo "==> squashing origin/${old_branch} onto ${new_branch} (staged, no commit)"
# --squash stages the merge result without creating a commit. It handles adds,
# deletes and renames correctly, unlike `checkout -- .`.
if ! git merge --squash "origin/${old_branch}"; then
  echo "error: merge --squash hit conflicts between origin/${old_branch} and the latest ${base}." >&2
  echo "The newer ${base} and the feature branch changed the same lines." >&2
  git --no-pager diff --name-only --diff-filter=U >&2 || true
  cd "${repo_root}"
  git worktree remove --force "${worktree_path}" >/dev/null 2>&1 || true
  git branch -D "${new_branch}" >/dev/null 2>&1 || true
  echo "Resolve by bringing the old branch up to date first (pr-merge-main), then re-run." >&2
  exit 1
fi

echo "==> verifying no content was lost"
# Compare feature CONTRIBUTIONS rather than whole trees, so this holds even when
# the default branch has advanced. The index sits on top of origin/<base>
# (HEAD), so `git diff --cached origin/<base>` is exactly what the new branch
# adds over the latest default branch, and `origin/<base>...origin/<old>` is
# what the old branch added over its merge base.
#
# Compared by `git patch-id --stable`, a content hash of the changed lines,
# rather than raw diff text: patch-id ignores the `index <sha>..<sha>` blob
# lines and hunk line-number offsets, so an advance of the default branch that
# shifted line numbers no longer trips a false "content lost". They still
# differ if the newer default branch re-contextualized the change or something
# was genuinely lost, which is exactly when we want to stop.
new_feature="$(git diff --cached "origin/${base}" | git patch-id --stable | awk '{print $1}')"
old_feature="$(git diff "origin/${base}...origin/${old_branch}" | git patch-id --stable | awk '{print $1}')"
if [[ "${new_feature}" != "${old_feature}" ]]; then
  echo "error: the squashed diff does not match origin/${old_branch}'s diff vs ${base}." >&2
  echo "The newer ${base} likely changed the same lines (needs a real merge), or something was lost." >&2
  echo "The worktree is left in place at ${worktree_path} so you can review:" >&2
  git --no-pager diff --cached --stat >&2
  exit 1
fi

echo
echo "OK. Full diff staged on ${new_branch}. Nothing lost vs origin/${old_branch}."
echo "Worktree: ${worktree_path}"
echo "Next: cd ${worktree_path} && git commit -m '<subject>'   (NO --no-verify, the hooks are the point)"
git --no-pager diff --cached --stat | tail -1
