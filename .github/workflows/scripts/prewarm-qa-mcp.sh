#!/usr/bin/env bash
set -uo pipefail

# Pre-warm the browser MCP server packages so that when claude-code-action
# subsequently launches them via `npx --yes`, the package is already
# cached on the runner and no registry round-trip is needed.
#
# The QA workflow's most common failure mode is npx flaking on a transient
# registry hiccup. When that happens the MCP server never starts,
# claude-code-action runs the agent with no `mcp__playwright__*` tools,
# and the agent falls into its "could not run" path. We can't observe
# the original npx failure from inside the agent — the user only sees
# the no-op comment with no clue WHY.
#
# This script:
#   1. Tries to install + boot each package up-front with exponential
#      backoff retries (3 attempts).
#   2. Captures every attempt's stderr to a log file under ARTIFACTS_DIR.
#   3. When BOTH packages fail, writes a diagnostic `_comment.md` so the
#      post-comment step posts a useful message to the PR (with log tails
#      and a link to the workflow run). Sets step outputs the workflow
#      uses to skip the (otherwise wasted) AI QA Review step.
#
# We deliberately do NOT fail when only one of the two packages fails —
# the agent's prompt treats Chrome DevTools MCP as a fallback for
# Playwright MCP and vice versa, so as long as one loads, browser QA
# is possible.
#
# Required env vars:
#   ARTIFACTS_DIR  - directory for logs and (on total failure) _comment.md
#   GITHUB_OUTPUT  - GitHub Actions step output file
#   RUN_URL        - URL to the calling workflow run (for the failure comment)
#
# Step outputs written to GITHUB_OUTPUT:
#   playwright-ok=true|false
#   chrome-devtools-ok=true|false
#   any-ok=true|false

: "${ARTIFACTS_DIR:?}" "${GITHUB_OUTPUT:?}" "${RUN_URL:?}"

mkdir -p "${ARTIFACTS_DIR}"

# Per-package config: name, npm spec, log filename, output key.
PACKAGES=(
  'Playwright MCP|@playwright/mcp@latest|mcp-prewarm-playwright.log|playwright-ok'
  'Chrome DevTools MCP|chrome-devtools-mcp@latest|mcp-prewarm-chrome-devtools.log|chrome-devtools-ok'
)

# Attempt to fetch + boot a package. Success means npx successfully
# resolved the package AND the binary exited cleanly on `--help`. We probe
# with `--help` rather than spawning the MCP server proper because the
# server is long-running by design (stdin-driven stdio transport) and
# would never exit on its own.
prewarm_one() {
  local label="$1" spec="$2" log_file="$3"
  local log_path="${ARTIFACTS_DIR}/${log_file}"
  : >"${log_path}"

  local attempt
  for attempt in 1 2 3; do
    echo "::group::Pre-warm ${label} (attempt ${attempt}/3)"
    local start_msg
    start_msg="[$(date -u +%FT%TZ)] Attempt ${attempt}: npx --yes ${spec} --help"
    echo "${start_msg}" | tee -a "${log_path}"

    # 90s budget per attempt: cold npx fetches can be slow on
    # GitHub-hosted runners (especially right after a registry blip).
    timeout 90 npx --yes "${spec}" --help </dev/null 2>&1 | tee -a "${log_path}"
    local rc=$?
    if (( rc == 0 )); then
      echo "[$(date -u +%FT%TZ)] Attempt ${attempt}: success" | tee -a "${log_path}"
      echo "::endgroup::"
      return 0
    fi
    echo "[$(date -u +%FT%TZ)] Attempt ${attempt}: failed with exit ${rc}" | tee -a "${log_path}"
    echo "::endgroup::"

    if (( attempt < 3 )); then
      local sleep_for=$(( attempt * attempt * 2 ))  # 2s, 8s
      echo "::warning::${label} pre-warm attempt ${attempt} failed; retrying in ${sleep_for}s"
      sleep "${sleep_for}"
    fi
  done

  echo "::error::${label} pre-warm failed after 3 attempts. See ${log_path}"
  return 1
}

ANY_OK=false
PLAYWRIGHT_OK=false
CHROME_DEVTOOLS_OK=false
FAILED_LABELS=()
FAILED_LOGS=()

for entry in "${PACKAGES[@]}"; do
  IFS='|' read -r label spec log_file output_key <<<"${entry}"
  if prewarm_one "${label}" "${spec}" "${log_file}"; then
    case "${output_key}" in
      playwright-ok)      PLAYWRIGHT_OK=true ;;
      chrome-devtools-ok) CHROME_DEVTOOLS_OK=true ;;
    esac
    ANY_OK=true
  else
    FAILED_LABELS+=("${label}")
    FAILED_LOGS+=("${ARTIFACTS_DIR}/${log_file}")
  fi
done

{
  echo "playwright-ok=${PLAYWRIGHT_OK}"
  echo "chrome-devtools-ok=${CHROME_DEVTOOLS_OK}"
  echo "any-ok=${ANY_OK}"
} >>"${GITHUB_OUTPUT}"

if [[ "${ANY_OK}" == "true" ]]; then
  if (( ${#FAILED_LABELS[@]} > 0 )); then
    echo "::warning::Pre-warm failed for: ${FAILED_LABELS[*]}. The agent will run with the loaded MCP(s) only."
  else
    echo "All browser MCP packages pre-warmed successfully."
  fi
  exit 0
fi

# Both failed — write a diagnostic comment so the post-comment step can
# post a useful message to the PR. Including the tail of the install
# logs means the user sees the actual root cause inline.
#
# The verdict tail is BLOCKING:YES / MAX_PRIORITY:UNKNOWN, never NO/NONE:
# QA checked nothing, so the verdict must not read as a pass to a human or
# to an agent (e.g. the babysit skill) that parses the tail. UNKNOWN (which
# a real report never writes) marks it as a non-report to re-run rather
# than a finding to fix.
COMMENT_FILE="${ARTIFACTS_DIR}/_comment.md"

LOG_TAILS=""
for log in "${FAILED_LOGS[@]}"; do
  if [[ -s "${log}" ]]; then
    LOG_TAILS+="<details><summary><code>$(basename "${log}")</code> (last 40 lines)</summary>"$'\n\n'
    LOG_TAILS+='```'$'\n'
    LOG_TAILS+="$(tail -n 40 "${log}")"$'\n'
    LOG_TAILS+='```'$'\n\n'
    LOG_TAILS+="</details>"$'\n\n'
  fi
done

cat >"${COMMENT_FILE}" <<EOF
<!-- ai-qa-review -->

## 🤖 AI QA Review — could not run

Browser automation was unavailable in this run: neither the Playwright MCP nor the Chrome DevTools MCP could be installed by \`npx\`. The QA pass is a no-op — no browser session, no screenshots, no video evidence.

### Diagnostic

Pre-install attempted 3× per package with exponential backoff and still failed. See the [workflow run](${RUN_URL}) for the full logs, or expand the tails below.

${LOG_TAILS}

If this is happening repeatedly, investigate the workflow's MCP configuration in \`.github/workflows/ai-qa-review.yml\` and the prewarm script at \`.github/workflows/scripts/prewarm-qa-mcp.sh\`.

QA has not checked this PR, so this is not a pass. If a code-review workflow (\`claude-pr-review\`) also runs on this repo, its comment is your signal for this PR in the meantime.

AI_QA_BLOCKING:YES
AI_QA_MAX_PRIORITY:UNKNOWN
EOF

echo "::error::Both browser MCP packages failed to pre-warm. Wrote diagnostic to ${COMMENT_FILE}."
# Exit 0 so the workflow continues (the post-comment step picks up the
# diagnostic). The AI QA Review step is gated on `any-ok=true` and skipped.
exit 0
