#!/usr/bin/env bash
set -euo pipefail

# Resolve which codebase review area(s) are DUE on this run.
#
# Adaptive scheduling model
# ─────────────────────────
# The workflow cron fires once a day. Each run this script asks, per area,
# "is a fresh review due yet?" — and the answer depends on whether you've
# been MERGING that area's review PRs. The goal: keep reviewing areas you
# actively engage with, and stop churning out reviews for areas you've
# left untouched (while never letting an area go completely silent).
#
# For each area we read GitHub state via `gh` (all `review(<area>):`
# issues + PRs, plus which review PRs have merged) and pick an interval
# from a three-tier cadence:
#
#   fast    — the latest review PR MERGED and nothing is open now.
#             Anchor: the merge time. You merged it → here's the next one
#             soon. (weekly areas: 7d after merge / daily areas: 1d)
#   slow    — a review PR merged within the dormant window, but the most
#             recent review is still OPEN/unmerged. Anchor: when that
#             review was created. You're engaged but haven't merged the
#             latest → a fresh one monthly. (weekly: 30d / daily: 7d)
#   dormant — no review PR has merged for DORMANT_AFTER (or ever). Anchor:
#             the last review's creation. We back off to a floor so we
#             don't pile up reviews nobody acts on, but never go fully
#             silent. (weekly: 90d quarterly / daily: 30d monthly)
#
# An area is emitted when `now >= anchor + interval`. Producing a review
# advances the anchor (a new issue/PR appears with createdAt≈now), so an
# area fires once per due window, not every run. Merging a review PR
# re-engages the area and snaps it back to the fast cadence. The "due"
# check is sticky — an area stays due until a review is produced — so a
# once-daily poll never skips an area waiting on it.
#
# When no area is due, we emit `areas_json=[]`, the downstream matrix is
# empty, and the review job is skipped. `close-superseded-reviews.sh`
# still closes older open issues/PRs in an area whenever a fresh one is
# produced.
#
# Portable: dates are parsed with jq (`fromdateiso8601`), not GNU `date -d`,
# so this runs (and its tests pass) on Linux runners and macOS alike.
#
# Required env vars:
#   GITHUB_OUTPUT
#   EVENT_NAME - "workflow_dispatch", "schedule", or "pull_request"
#   REPO       - owner/repo (scheduled runs only; used by `gh`)
#   GH_TOKEN   - token with issues:read + pull-requests:read (scheduled runs)
#
# Optional env vars:
#   INPUT_REVIEW_AREA   - the area chosen by the user (workflow_dispatch only)
#   NOW_EPOCH_SECONDS   - override "now" (testing only; defaults to wall clock)

: "${GITHUB_OUTPUT:?}" "${EVENT_NAME:?}"

# Reordering these lists is harmless; adding/removing an area just adds or
# removes it from the rotation. Membership in DAILY_AREAS selects the
# tighter, revenue-critical intervals below. Every area here needs a
# matching `.github/review-prompts/<area>.md` and an entry in the
# `workflow_dispatch` options list in codebase-review.yml.
DAILY_AREAS=(
  billing-integrity
  e-commerce
)

WEEKLY_AREAS=(
  ai-compliance
  architecture
  code-quality
  compliance
  correctness
  dependency-health
  documentation
  error-handling
  infrastructure
  performance-client
  performance-server
  privacy
  resilience
  scalability
  security
  testing
)

# Cadence intervals, in HOURS. See the three-tier model in the header.
WEEKLY_FAST=168    # 7d  — next review after a merge
WEEKLY_SLOW=720    # 30d — fresh monthly review while latest sits unmerged
WEEKLY_FLOOR=2160  # 90d — quarterly floor once dormant
DAILY_FAST=24      # 1d  — revenue-critical areas after a merge
DAILY_SLOW=168     # 7d  — revenue-critical areas weekly while unmerged
DAILY_FLOOR=720    # 30d — revenue-critical monthly floor (never quarterly)
DORMANT_AFTER=1440 # 60d without a merged review PR => dormant

# Single source of truth for the `all` choice of workflow_dispatch. The
# choice list under `workflow_dispatch.inputs.review_area.options:` in
# codebase-review.yml must still be kept in sync by hand — GitHub
# requires that list to be static YAML.
ALL_AREAS_JSON=$(
  printf '%s\n' "${DAILY_AREAS[@]}" "${WEEKLY_AREAS[@]}" \
    | LC_ALL=C sort \
    | jq -R . \
    | jq -cs .
)

# ─── workflow_dispatch ───────────────────────────────────────────────────
if [[ "${EVENT_NAME}" = "workflow_dispatch" ]]; then
  AREA="${INPUT_REVIEW_AREA:-security}"
  if [[ "${AREA}" = "all" ]]; then
    echo "areas_json=${ALL_AREAS_JSON}" >> "${GITHUB_OUTPUT}"
  else
    echo "areas_json=[\"${AREA}\"]" >> "${GITHUB_OUTPUT}"
  fi
  exit 0
fi

# ─── pull_request ────────────────────────────────────────────────────────
# If you add a pull_request trigger to exercise the pipeline end-to-end on
# a dev branch, it always produces exactly one review, regardless of GitHub
# state, so the run isn't a no-op.
if [[ "${EVENT_NAME}" = "pull_request" ]]; then
  echo "areas_json=[\"${WEEKLY_AREAS[0]}\"]" >> "${GITHUB_OUTPUT}"
  exit 0
fi

# ─── Scheduled: adaptive per-area due check ──────────────────────────────
: "${REPO:?}"
NOW_S="${NOW_EPOCH_SECONDS:-$(date -u +%s)}"

# Pull all auto-review issues and PRs once (two API calls), then evaluate
# each area against the in-memory JSON.
ISSUES_JSON=$(gh issue list --repo "${REPO}" --label auto-review --state all \
  --limit 1000 --json number,title,createdAt)
PRS_JSON=$(gh pr list --repo "${REPO}" --label auto-review --state all \
  --limit 1000 --json number,title,createdAt,mergedAt,state)
CREATED_JSON=$(jq -s '.[0] + .[1]' <(printf '%s' "${ISSUES_JSON}") <(printf '%s' "${PRS_JSON}"))

# GitHub timestamps are `YYYY-MM-DDTHH:MM:SSZ`, exactly what jq parses.
iso_to_epoch() { jq -rn --arg d "$1" '$d | fromdateiso8601'; }

DUE_AREAS=()

for area in "${DAILY_AREAS[@]}" "${WEEKLY_AREAS[@]}"; do
  prefix="review(${area}):"

  if [[ " ${DAILY_AREAS[*]} " == *" ${area} "* ]]; then
    fast="${DAILY_FAST}"; slow="${DAILY_SLOW}"; floor="${DAILY_FLOOR}"
  else
    fast="${WEEKLY_FAST}"; slow="${WEEKLY_SLOW}"; floor="${WEEKLY_FLOOR}"
  fi

  # Most recent review of any kind (issue or PR, any state) for this area.
  last_created=$(printf '%s' "${CREATED_JSON}" | jq -r --arg p "${prefix}" \
    '[.[] | select(.title | startswith($p)) | .createdAt] | max // empty')

  # Never reviewed → bootstrap: due now.
  if [[ -z "${last_created}" ]]; then
    DUE_AREAS+=("${area}")
    continue
  fi

  # Most recent MERGED review PR, and whether one is open right now.
  last_merged=$(printf '%s' "${PRS_JSON}" | jq -r --arg p "${prefix}" \
    '[.[] | select(.title | startswith($p)) | select(.mergedAt != null) | .mergedAt] | max // empty')
  open_pr=$(printf '%s' "${PRS_JSON}" | jq -r --arg p "${prefix}" \
    'any(.[]; (.title | startswith($p)) and .state == "OPEN")')

  created_s=$(iso_to_epoch "${last_created}")
  merged_s=""
  if [[ -n "${last_merged}" ]]; then
    merged_s=$(iso_to_epoch "${last_merged}")
  fi

  # Engaged = a review PR merged within the dormant window.
  engaged=false
  if [[ -n "${merged_s}" ]] && (( (NOW_S - merged_s) < DORMANT_AFTER * 3600 )); then
    engaged=true
  fi

  if ${engaged}; then
    if [[ "${open_pr}" == "true" ]]; then
      anchor_s="${created_s}"; interval="${slow}"   # unmerged backlog → slow
    else
      anchor_s="${merged_s}"; interval="${fast}"     # just merged → fast
    fi
  else
    anchor_s="${created_s}"; interval="${floor}"     # dormant → floor
  fi

  if (( NOW_S >= anchor_s + interval * 3600 )); then
    DUE_AREAS+=("${area}")
  fi
done

if (( ${#DUE_AREAS[@]} == 0 )); then
  echo "areas_json=[]" >> "${GITHUB_OUTPUT}"
else
  JSON=$(printf '"%s",' "${DUE_AREAS[@]}")
  echo "areas_json=[${JSON%,}]" >> "${GITHUB_OUTPUT}"
fi
