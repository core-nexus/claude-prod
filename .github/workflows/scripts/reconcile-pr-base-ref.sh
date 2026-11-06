#!/usr/bin/env bash
# Point claude-code-action's trusted-config restore at the repository's
# default branch instead of whatever branch the PR happens to target.
#
# ── Why this exists ───────────────────────────────────────────────────────
#
# Before running the agent, claude-code-action replaces the PR checkout's
# `.claude/`, `.mcp.json`, `CLAUDE.md`, `.husky`, … with the versions from
# the PR's base branch — those paths are executable config that the CLI
# reads from cwd at startup, so on a PR they are attacker-controlled. That
# restore is a `git fetch origin <base-ref> --depth=1`, and the ref it uses
# comes from ONE place: `.pull_request.base.ref` in the webhook payload
# (src/entrypoints/run.ts → restoreConfigFromBase). Everything else in the
# action reads the base from the live API instead.
#
# The payload is frozen when the event fires. The QA job then idles for up
# to 20 minutes waiting for the preview to deploy. On a stacked
# PR that window is long enough for the parent PR to merge — at which point
# GitHub deletes the parent branch and auto-retargets this PR to `main`
# (an `automatic_base_change_succeeded` timeline event). The frozen payload
# still names the deleted branch, so the fetch dies:
#
#   Restoring … from origin/feat/parent-branch (PR head is untrusted)
#   fatal: couldn't find remote ref feat/parent-branch
#
# …and the whole job fails before the browser ever opens. In the incident
# that motivated this script the parent merged, GitHub retargeted the PR to
# `main` two seconds later, and the restore ran ~7 minutes after that, still
# asking for the dead ref.
# (`--depth=1` is a red herring — `git fetch origin <name>` resolves the
# name on the server, so clone depth is irrelevant; `couldn't find remote
# ref` means the branch is simply not there.)
#
# ── Why the default branch, rather than re-resolving the live base ────────
#
# Re-resolving would fix the deleted-branch case but leaves the underlying
# problem: a stacked PR's base is *another unreviewed PR branch*, so
# restoring "trusted" config from it restores config nobody has reviewed —
# exactly what the restore exists to prevent. The default branch is the
# only ref that is both genuinely reviewed and guaranteed to still exist,
# which closes the race instead of narrowing it.
#
# Blast radius is one field: `.pull_request.base.ref` is read nowhere else
# in the action (verified against the pinned revision). The PR's real base
# still drives merge behaviour, the preview deploy, and the diff the agent
# reviews — all of those read the live API, not this field.
#
# ── Contract ─────────────────────────────────────────────────────────────
#
# Input:  $GITHUB_EVENT_PATH (the runner's event payload file).
# Effect: rewrites `.pull_request.base.ref` to the repo's default branch,
#         in place, when the two differ. No network calls — the default
#         branch is already in the payload.
# Exit 0: reconciled, or nothing to reconcile (already the default branch,
#         no `pull_request` in the payload, no default branch to aim at,
#         missing/malformed payload). In every no-op case the action keeps
#         behaving exactly as it does without this script.
# Exit 1: a rewrite was needed but did not land. Failing here — cheaply,
#         with both ref names in the message — beats failing inside the
#         action minutes later with a bare git fatal.
#
# Tested by reconcile-pr-base-ref.test.sh.

set -uo pipefail

EVENT_PATH="${GITHUB_EVENT_PATH:-}"

if [[ -z "${EVENT_PATH}" || ! -r "${EVENT_PATH}" ]]; then
  echo "No readable GITHUB_EVENT_PATH; leaving the restore base alone."
  exit 0
fi

# One jq pass, tab-separated, so a malformed payload fails once here rather
# than twice below. `.pull_request.base.repo.default_branch` is preferred
# over `.repository.default_branch` because on a fork PR the former is
# unambiguously the *base* repo's default.
FIELDS="$(jq -r '
  [ (.pull_request.base.ref // ""),
    (.pull_request.base.repo.default_branch // .repository.default_branch // "")
  ] | @tsv' "${EVENT_PATH}" 2>/dev/null)" || FIELDS=''

if [[ -z "${FIELDS}" ]]; then
  echo "Event payload is not readable as JSON; leaving the restore base alone."
  exit 0
fi

IFS=$'\t' read -r BASE_REF DEFAULT_BRANCH <<< "${FIELDS}"

# `issue_comment` (`/qa-review`) payloads carry no `pull_request.base` — the
# action resolves the base from the API on that path, so there is nothing
# here to correct.
if [[ -z "${BASE_REF}" ]]; then
  echo "No pull_request.base.ref in the event payload; nothing to reconcile."
  exit 0
fi

if [[ -z "${DEFAULT_BRANCH}" ]]; then
  echo "Event payload names no default branch; leaving base ref '${BASE_REF}' alone."
  exit 0
fi

if [[ "${BASE_REF}" == "${DEFAULT_BRANCH}" ]]; then
  echo "PR base ref is already the default branch ('${DEFAULT_BRANCH}'); nothing to reconcile."
  exit 0
fi

echo "PR targets '${BASE_REF}', not the default branch '${DEFAULT_BRANCH}'."
echo "Repointing the agent's trusted-config restore at '${DEFAULT_BRANCH}'."

# Render to a temp file first, then copy the bytes into the existing file.
# Writing through the original path (rather than `mv`-ing over it) keeps the
# runner's inode and permissions untouched.
TMP_PAYLOAD="$(mktemp -t reconciled-event-XXXXXX)"
trap 'rm -f "${TMP_PAYLOAD}"' EXIT

jq --arg default "${DEFAULT_BRANCH}" \
  '.pull_request.base.ref = $default' "${EVENT_PATH}" > "${TMP_PAYLOAD}" \
  && cat "${TMP_PAYLOAD}" > "${EVENT_PATH}"

# Verify against the file the action will actually read, rather than trusting
# the exit codes above: a partial write or a read-only payload must surface
# here, not as `fatal: couldn't find remote ref` inside the action.
WROTE="$(jq -r '.pull_request.base.ref // ""' "${EVENT_PATH}" 2>/dev/null)" || WROTE=''
if [[ "${WROTE}" != "${DEFAULT_BRANCH}" ]]; then
  echo "::error::Could not repoint the config restore from '${BASE_REF}' to '${DEFAULT_BRANCH}'" \
    "— the event payload at ${EVENT_PATH} still reads '${WROTE}'." \
    "The agent would fail on 'git fetch origin ${BASE_REF}' if that branch is gone." >&2
  exit 1
fi

echo "Reconciled: the config restore will use origin/${DEFAULT_BRANCH}."
