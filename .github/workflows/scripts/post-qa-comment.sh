#!/usr/bin/env bash
set -euo pipefail

# Post the QA review report as a PR comment. Uses GitHub Actions artifacts
# only and links to them from the comment (no external media host needed).
#
# Behavior:
#   - Reads the agent's draft from $ARTIFACTS_DIR/_comment.md.
#   - Strips any line that references a `./qa-artifacts/<file>` the agent
#     never saved to disk (it forgot `filename:` on the screenshot call),
#     with a note, so the comment shows no broken images.
#   - Replaces relative `./qa-artifacts/<file>` references with the
#     artifact-bundle download URL (since GitHub PR comments can't
#     render images from a runner filesystem path).
#   - If $MEDIA_BASE_URL is set, rewrites those refs to
#     `${MEDIA_BASE_URL}/<file>` instead — useful when you've mirrored
#     the captured media to a public host (e.g. another GitHub repo,
#     S3, your CDN) and want inline image rendering. Set it in a step
#     that runs BEFORE this one.
#   - Makes `<!-- ai-qa-review -->` the first line, and fails CLOSED when
#     the machine-readable tail is missing: appends AI_QA_BLOCKING:YES /
#     AI_QA_MAX_PRIORITY:HIGH so a truncated report is never read as a pass.
#   - Deletes the starting-ack comment posted by post-qa-starting-comment.sh.
#   - Posts the body as a new PR comment.
#   - If _comment.md is missing/empty, posts a stand-in whose verdict does
#     NOT read as a pass (AI_QA_BLOCKING:YES, AI_QA_MAX_PRIORITY:UNKNOWN),
#     then exits 1 so the step goes red.
#
# Required env vars:
#   GH_TOKEN        - token with issues:write on REPO
#   REPO            - owner/repo
#   PR_NUMBER       - PR number
#   RUN_ID          - github.run_id of the calling workflow run
#   ARTIFACTS_DIR   - directory containing _comment.md and media
#   ARTIFACT_NAME   - name of the workflow artifact bundle to link to
#
# Optional env vars:
#   SERVER_URL      - github.server_url (default: https://github.com)
#   QA_RESULT       - job.status of the qa step (success|failure|cancelled)
#   MEDIA_BASE_URL  - if set, rewrite ./qa-artifacts/<f> → $MEDIA_BASE_URL/<f>
#                     (must not contain `|`, the sed delimiter)
#
# Tested by post-qa-comment.test.sh.

: "${GH_TOKEN:?}" "${REPO:?}" "${PR_NUMBER:?}" "${RUN_ID:?}" "${ARTIFACTS_DIR:?}" "${ARTIFACT_NAME:?}"

SERVER_URL="${SERVER_URL:-https://github.com}"
QA_RESULT="${QA_RESULT:-success}"
MEDIA_BASE_URL="${MEDIA_BASE_URL:-}"

RUN_URL="${SERVER_URL}/${REPO}/actions/runs/${RUN_ID}"
ARTIFACT_URL="${RUN_URL}#artifacts"
COMMENT_FILE="${ARTIFACTS_DIR}/_comment.md"
STARTING_MARKER='<!-- ai-qa-review-starting -->'
REPORT_MARKER='<!-- ai-qa-review -->'

# Always try to delete the starting-ack comment so we don't leave it
# hanging next to the final report.
delete_starting_ack() {
  local ids
  ids=$(gh api "repos/${REPO}/issues/${PR_NUMBER}/comments" --paginate \
    | jq -r --arg marker "${STARTING_MARKER}" \
        '.[] | select(.body | contains($marker)) | .id')
  if [[ -z "${ids}" ]]; then
    return
  fi
  while read -r id; do
    [[ -z "${id}" ]] && continue
    echo "Deleting starting-ack comment (id=${id})"
    gh api -X DELETE "repos/${REPO}/issues/comments/${id}" >/dev/null \
      || echo "::warning::Failed to delete starting-ack comment id=${id}"
  done <<<"${ids}"
}

post_comment() {
  local body_file="$1"
  echo "Posting QA review comment to PR #${PR_NUMBER}"
  jq -Rs '{body: .}' < "${body_file}" \
    | gh api -X POST --input - "repos/${REPO}/issues/${PR_NUMBER}/comments" >/dev/null
}

# Stand-in for a run whose agent left no report. QA checked nothing, so
# the verdict must not read as a pass: BLOCKING:YES keeps every reader
# from treating the PR as cleared, and MAX_PRIORITY:UNKNOWN (never written
# by the agent) tells the babysit skill this is a non-report to re-run,
# not a finding to fix.
write_fallback() {
  cat <<EOF
${REPORT_MARKER}

## 🤖 AI QA Review — no report produced

The QA agent did not write a report (\`_comment.md\` missing or empty). This usually means the agent crashed before its final write step, or the workflow was cancelled mid-run.

QA has not checked this PR, so this is not a pass. Re-run QA (\`/qa-review\`) once the cause is fixed.

- **Job status:** \`${QA_RESULT}\`
- [Workflow run](${RUN_URL})
- [Artifact bundle](${ARTIFACT_URL}) (may be empty)

If this is happening repeatedly, check the workflow logs and the QA pre-warm step in particular.

AI_QA_BLOCKING:YES
AI_QA_MAX_PRIORITY:UNKNOWN
EOF
}

# Drop every line that references a `./qa-artifacts/<name>` missing from
# ARTIFACTS_DIR, then note the strip above the verdict tail (or at the end
# when there is no tail). Deleting the whole line beats a partial edit that
# could mangle adjacent prose; image/video tags sit on their own lines.
strip_broken_refs() {
  local comment="$1"
  local referenced name
  # `|| true`: no references at all is a valid report, not an error.
  referenced=$(grep -oE "\\./qa-artifacts/[A-Za-z0-9._-]+" "${comment}" \
    | sed -E 's|^\./qa-artifacts/||' | sort -u || true)

  local missing=()
  while IFS= read -r name; do
    [[ -z "${name}" ]] && continue
    [[ -f "${ARTIFACTS_DIR}/${name}" ]] || missing+=("${name}")
  done <<<"${referenced}"
  (( ${#missing[@]} == 0 )) && return 0

  echo "::warning::QA report references ${#missing[@]} artifact file(s) not on disk; stripping those lines."
  local script='' safe
  for name in "${missing[@]}"; do
    echo "::warning::  missing: ${name}"
    safe=$(printf '%s\n' "${name}" | sed -e 's/[][\/.^$*]/\\&/g')
    script+="/${safe}/d;"
  done
  sed -E "${script}" "${comment}" > "${comment}.tmp" && mv "${comment}.tmp" "${comment}"

  # A read loop rather than `awk -v`: awk cannot carry a newline in a -v
  # value on either BSD or GNU awk.
  local note line inserted=false
  note="> _Note: ${#missing[@]} artifact reference(s) were stripped because the QA agent did not save the file to disk (pass \`filename:\` to the screenshot call)._"
  while IFS= read -r line || [[ -n "${line}" ]]; do
    if ! ${inserted} && [[ "${line}" =~ ^[[:space:]]*AI_QA_BLOCKING: ]]; then
      printf '%s\n\n' "${note}"
      inserted=true
    fi
    printf '%s\n' "${line}"
  done < "${comment}" > "${comment}.tmp"
  ${inserted} || printf '\n%s\n' "${note}" >> "${comment}.tmp"
  mv "${comment}.tmp" "${comment}"
}

# Rewrite ./qa-artifacts/<file> references to a public host, or (with no
# host) to the artifact bundle, adding a note that says where the media is.
rewrite_refs() {
  local comment="$1"
  if [[ -n "${MEDIA_BASE_URL}" ]]; then
    sed -E "s|\\./qa-artifacts/([^[:space:])\"<>]+)|${MEDIA_BASE_URL%/}/\\1|g" \
      "${comment}" > "${comment}.tmp"
    mv "${comment}.tmp" "${comment}"
    return 0
  fi

  # Inline images become links to the bundle; any other ref becomes the URL.
  # `|` delimits the sed expressions: the URLs contain `#` (`#artifacts`).
  sed -E \
    -e "s|!\\[([^]]*)\\]\\(\\./qa-artifacts/([^)]+)\\)|[\\1 (\`\\2\` — download from artifact bundle)](${ARTIFACT_URL})|g" \
    -e "s|\\./qa-artifacts/([^[:space:])\"<>]+)|${ARTIFACT_URL}|g" \
    "${comment}" > "${comment}.tmp"
  mv "${comment}.tmp" "${comment}"
  {
    printf '> 📦 Screenshot/video evidence for this run is bundled as a workflow artifact: [%s](%s)\n>\n' \
      "${ARTIFACT_NAME}" "${ARTIFACT_URL}"
    # shellcheck disable=SC2016  # backticks are literal Markdown.
    printf '> To inline screenshots in PR comments, set `MEDIA_BASE_URL` in the post-comment step to a public host where you mirror the captured media.\n\n'
    cat "${comment}"
  } > "${comment}.tmp"
  mv "${comment}.tmp" "${comment}"
}

# The marker must be the very first line (other agents look for it), so
# drop it wherever the agent put it and re-add it on top.
ensure_marker_first() {
  local comment="$1"
  {
    printf '%s\n\n' "${REPORT_MARKER}"
    grep -avF "${REPORT_MARKER}" "${comment}" || true
  } > "${comment}.tmp"
  mv "${comment}.tmp" "${comment}"
}

# Fail closed: a body without the verdict tail (e.g. the agent was cut off
# mid-report) defaults to YES/HIGH so a human has to look. Defaulting to
# NO/NONE would hide the findings written above it. Leading whitespace is
# tolerated so a tail indented inside a list or <details> still counts.
ensure_verdict_tail() {
  local comment="$1"
  if ! grep -qE '^[[:space:]]*AI_QA_BLOCKING:' "${comment}"; then
    echo "::warning::QA report has no AI_QA_BLOCKING tail; defaulting to YES/HIGH so a human reviews."
    printf '\nAI_QA_BLOCKING:YES\nAI_QA_MAX_PRIORITY:HIGH\n' >> "${comment}"
  fi
}

FINAL_COMMENT="$(mktemp)"
trap 'rm -f "${FINAL_COMMENT}" "${FINAL_COMMENT}.tmp"' EXIT

delete_starting_ack

if [[ ! -s "${COMMENT_FILE}" ]]; then
  echo "::error::No QA report at ${COMMENT_FILE} (missing or empty); posting a non-pass stand-in, then failing."
  write_fallback > "${FINAL_COMMENT}"
  post_comment "${FINAL_COMMENT}"
  exit 1
fi

cp "${COMMENT_FILE}" "${FINAL_COMMENT}"
strip_broken_refs "${FINAL_COMMENT}"
rewrite_refs "${FINAL_COMMENT}"
ensure_marker_first "${FINAL_COMMENT}"
ensure_verdict_tail "${FINAL_COMMENT}"
post_comment "${FINAL_COMMENT}"

echo "Done."
