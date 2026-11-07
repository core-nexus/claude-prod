#!/usr/bin/env bash
set -uo pipefail

# Handle a claude[bot] tracking comment when the job fails or is cancelled.
#
# `anthropics/claude-code-action@v1` with `track_progress: true` creates a
# GitHub comment that updates throughout the run's lifecycle. If the job
# fails or is cancelled (including via `timeout-minutes`), this comment is
# left stuck in an "in progress" state — misleading on the PR timeline,
# and a poor diagnostic if it gets deleted entirely.
#
# Policy:
# never DELETE a tracking comment that records what a job actually did.
# Always preserve the body and append a clearly-marked failure banner so
# the user sees both (a) what the agent had time to do, and (b) that the
# run did not complete. The only `delete` use left in the tree is when a
# job succeeded AND a separate formatted report comment supersedes the
# tracking comment 1:1 — see ai-qa-review.yml.
#
# The action does NOT expose the tracking comment ID as an output, but it
# embeds a "View job" link of the form
# `https://github.com/<owner>/<repo>/actions/runs/<RUN_ID>` in the comment
# body. We match on that to find the tracking comment for THIS run.
#
# Required env:
#   GH_TOKEN   - GitHub token with issues:write (and actions:read for the
#                rich-banner reason lookup)
#   REPO       - owner/repo
#   PR_NUMBER  - pull request number
#   RUN_ID     - GitHub Actions run ID (github.run_id)
#   ACTION     - "delete" or "mark-failed"
#
# Optional env (used only by `mark-failed`):
#   JOB_NAME      - github.job — name of the calling job, used to home in
#                   on the right entry from the runs/<id>/jobs API. If
#                   omitted, we use the first failed job in the run.
#   ARTIFACTS_DIR - directory whose *.log files should be tailed into
#                   the banner inline (e.g., qa-artifacts/ for the MCP
#                   pre-warm output). Skipped if unset, missing, or empty.

: "${GH_TOKEN:?}" "${REPO:?}" "${PR_NUMBER:?}" "${RUN_ID:?}" "${ACTION:?}"

case "${ACTION}" in
  delete | mark-failed) ;;
  *)
    echo "ERROR: unknown ACTION='${ACTION}' (expected: delete | mark-failed)" >&2
    exit 1
    ;;
esac

RUN_URL_FRAGMENT="actions/runs/${RUN_ID}"
RUN_URL="https://github.com/${REPO}/${RUN_URL_FRAGMENT}"
BANNER_MARKER='<!-- claude-job-failure-banner -->'

echo "Looking for claude[bot] tracking comment referencing ${RUN_URL_FRAGMENT}..."

COMMENTS_JSON=$(gh api "repos/${REPO}/issues/${PR_NUMBER}/comments" --paginate)

MATCH_IDS=$(printf '%s' "${COMMENTS_JSON}" | jq --arg frag "${RUN_URL_FRAGMENT}" '
  [ .[]
    | select(.user.login == "claude[bot]")
    | select((.body // "") | contains($frag))
    | .id
  ] | .[]
')

if [[ -z "${MATCH_IDS}" ]]; then
  echo "No claude[bot] tracking comment found for run ${RUN_ID}. Nothing to do."
  exit 0
fi

# --- Reason discovery (mark-failed only) -----------------------------------
#
# Best-effort: query the jobs API to find which step actually failed and
# what conclusion the runner reported. If the lookup errors (token scope,
# network, rate limit), the banner falls back to the bare run-URL form so
# the user still gets a clearly-marked failure note rather than nothing.
build_failure_summary() {
  local jobs_json job_name="${JOB_NAME:-}"
  local job_data=''
  jobs_json=$(gh api "repos/${REPO}/actions/runs/${RUN_ID}/jobs" --paginate 2>/dev/null || printf '')

  if [[ -n "${jobs_json}" ]]; then
    if [[ -n "${job_name}" ]]; then
      job_data=$(printf '%s' "${jobs_json}" | jq -c --arg name "${job_name}" '
        .jobs[]?
        | select(.name == $name)
        | select(.conclusion != "success" and .conclusion != null)
      ' 2>/dev/null | head -1)
    fi
    # Fallback: if JOB_NAME wasn't provided or didn't match, take the
    # first failing job in the run — for the workflows that call this
    # script there's almost always exactly one.
    if [[ -z "${job_data}" ]]; then
      job_data=$(printf '%s' "${jobs_json}" | jq -c '
        .jobs[]?
        | select(.conclusion != "success" and .conclusion != null)
      ' 2>/dev/null | head -1)
    fi
  fi

  if [[ -z "${job_data}" ]]; then
    # Couldn't enrich — return the minimal banner.
    cat <<EOF
**Status:** Did not complete successfully — see the [workflow run](${RUN_URL}) for details.
EOF
    return 0
  fi

  local conclusion job_url failed_step_name failed_step_conclusion duration_human
  conclusion=$(printf '%s' "${job_data}" | jq -r '.conclusion // "unknown"')
  job_url=$(printf '%s' "${job_data}" | jq -r '.html_url // empty')
  failed_step_name=$(printf '%s' "${job_data}" | jq -r '
    [.steps[]? | select(.conclusion != "success" and .conclusion != "skipped" and .conclusion != null)][0]?
    | .name // empty
  ')
  failed_step_conclusion=$(printf '%s' "${job_data}" | jq -r '
    [.steps[]? | select(.conclusion != "success" and .conclusion != "skipped" and .conclusion != null)][0]?
    | .conclusion // empty
  ')

  # Compute job duration (best-effort).
  local started_at completed_at
  started_at=$(printf '%s' "${job_data}" | jq -r '.started_at // empty')
  completed_at=$(printf '%s' "${job_data}" | jq -r '.completed_at // empty')
  if [[ -n "${started_at}" && -n "${completed_at}" ]]; then
    local secs
    secs=$(( $(date -d "${completed_at}" +%s 2>/dev/null || echo 0) - \
             $(date -d "${started_at}" +%s 2>/dev/null || echo 0) ))
    if (( secs > 0 )); then
      if (( secs >= 60 )); then
        duration_human="$(( secs / 60 ))m $(( secs % 60 ))s"
      else
        duration_human="${secs}s"
      fi
    fi
  fi

  # Translate conclusion to user-friendly text. timeout-minutes triggers
  # render the failing step as "cancelled" while the job conclusion stays
  # "failure" — flag that explicitly so the user knows it's likely a timeout.
  local status_human="${conclusion}"
  case "${conclusion}" in
    failure)
      if [[ "${failed_step_conclusion}" == "cancelled" ]]; then
        status_human="failed (step cancelled — likely a \`timeout-minutes\` timeout)"
      else
        status_human="failed"
      fi
      ;;
    cancelled)   status_human="cancelled" ;;
    timed_out)   status_human="timed out" ;;
    skipped)     status_human="skipped" ;;
  esac

  {
    printf '**Status:** %s' "${status_human}"
    [[ -n "${duration_human}" ]] && printf ' after %s' "${duration_human}"
    printf '\n'
    if [[ -n "${failed_step_name}" ]]; then
      printf '**Failed step:** `%s`' "${failed_step_name}"
      [[ -n "${failed_step_conclusion}" && "${failed_step_conclusion}" != "${conclusion}" ]] \
        && printf ' (%s)' "${failed_step_conclusion}"
      printf '\n'
    fi
    if [[ -n "${job_url}" ]]; then
      printf '**Job logs:** [open in Actions](%s)\n' "${job_url}"
    else
      printf '**Workflow run:** [open in Actions](%s)\n' "${RUN_URL}"
    fi
  }
}

# Surface tail of any *.log files in ARTIFACTS_DIR (typically the QA
# pre-warm logs). Inlined into the banner inside <details> so the
# comment stays scannable but the actual error text is one click away.
build_artifact_tails() {
  local dir="${ARTIFACTS_DIR:-}"
  [[ -z "${dir}" ]] && return 0
  [[ -d "${dir}" ]] || return 0

  shopt -s nullglob
  local logs=( "${dir}"/*.log )
  shopt -u nullglob
  (( ${#logs[@]} > 0 )) || return 0

  printf '\n<details><summary>Local log tails (last 40 lines each)</summary>\n\n'
  local log
  for log in "${logs[@]}"; do
    [[ -s "${log}" ]] || continue
    printf '**`%s`**\n\n```\n' "$(basename "${log}")"
    tail -n 40 "${log}"
    printf '```\n\n'
  done
  printf '</details>\n'
}

# Strip any previous banner so re-runs of this script (e.g., a step that
# reruns or a workflow re-attempt) refresh the banner instead of stacking
# multiple copies on the same comment.
strip_existing_banner() {
  local body="$1"
  if [[ "${body}" == *"${BANNER_MARKER}"* ]]; then
    # Drop everything from the banner marker through end-of-string. The
    # marker is always the first line of the banner block, preceded by
    # a `\n\n---\n\n` separator that we also remove if present.
    body="${body%%${BANNER_MARKER}*}"
    body="${body%$'\n\n---\n\n'}"
    body="${body%$'\n---\n'}"
    body="${body%$'\n'}"
  fi
  printf '%s' "${body}"
}

while read -r COMMENT_ID; do
  [[ -z "${COMMENT_ID}" ]] && continue

  case "${ACTION}" in
    delete)
      echo "Deleting tracking comment ${COMMENT_ID}..."
      gh api -X DELETE "repos/${REPO}/issues/comments/${COMMENT_ID}"
      ;;
    mark-failed)
      echo "Building failure banner for tracking comment ${COMMENT_ID}..."

      EXISTING_BODY=$(gh api "repos/${REPO}/issues/comments/${COMMENT_ID}" --jq .body)
      EXISTING_BODY=$(strip_existing_banner "${EXISTING_BODY}")

      SUMMARY="$(build_failure_summary)"
      ARTIFACT_TAILS="$(build_artifact_tails)"

      # Construct via printf so embedded markers/newlines don't get
      # mangled by shell quoting. jq -Rs at the end JSON-encodes the
      # whole body for the PATCH payload.
      NEW_BODY=$(
        printf '%s\n\n---\n\n%s\n# ❌ This run did not complete successfully\n\n%s%s\n\n_Anything above is a partial record of what the agent had completed before the run stopped — it is preserved deliberately so you have a trail to debug from._\n' \
          "${EXISTING_BODY}" \
          "${BANNER_MARKER}" \
          "${SUMMARY}" \
          "${ARTIFACT_TAILS}"
      )

      printf '%s' "${NEW_BODY}" | jq -Rs '{ body: . }' \
        | gh api -X PATCH --input - "repos/${REPO}/issues/comments/${COMMENT_ID}" >/dev/null
      echo "Updated tracking comment ${COMMENT_ID}."
      ;;
    *)
      # Defensive: the earlier ACTION guard makes this unreachable.
      echo "ERROR: unreachable case ACTION='${ACTION}'" >&2
      exit 1
      ;;
  esac
done <<<"${MATCH_IDS}"

echo "Done."
