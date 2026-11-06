#!/usr/bin/env bash
# Fail when a sentry-triage run's Claude session had no working Sentry MCP.
#
# Usage: check-sentry-mcp-connected.sh <claude-execution-output.json>
#
# claude-code-action writes its transcript as a JSON array of SDK messages; the
# `system`/`init` message lists every MCP server with its connection status.
# When the Sentry MCP is not `connected`, Claude cannot read the issue, stops
# after a few turns and the action still reports success (typical causes: the
# wrong auth scheme in the MCP header, or a token that cannot read issues). That
# is a misconfiguration, so it must fail the job and reach your failure
# notification rather than pass quietly.
#
# This deliberately does NOT judge whether Claude opened a PR: declining to fix
# an issue (and commenting on it in Sentry instead) is a legitimate outcome.

set -euo pipefail

TRANSCRIPT="${1:?usage: check-sentry-mcp-connected.sh <execution-file>}"

if [[ ! -f "${TRANSCRIPT}" ]]; then
  echo "::error::Claude transcript not found at ${TRANSCRIPT}; cannot confirm the Sentry MCP connected."
  exit 1
fi

STATUS=$(jq -r '
  [.[] | select(.type == "system" and .subtype == "init")][0].mcp_servers // []
  | map(select(.name == "sentry"))[0].status // "absent"
' "${TRANSCRIPT}")

if [[ "${STATUS}" != "connected" ]]; then
  echo "::error::Sentry MCP status was '${STATUS}', not 'connected'. Claude could not read the Sentry issue, so this triage run did no real work. Check SENTRY_AUTH_TOKEN and the Sentry-Bearer header (docs/sentry-triage/setup.md)."
  exit 1
fi

echo "Sentry MCP connected."
