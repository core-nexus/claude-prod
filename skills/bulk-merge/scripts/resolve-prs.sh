#!/usr/bin/env bash
# Resolve a /bulk-merge argument into open, non-draft PR numbers (one per line).
#
#   resolve-prs.sh needs-merge                                  # a label
#   resolve-prs.sh 'label:needs-merge author:app/dependabot'    # GitHub search syntax
#   resolve-prs.sh 'https://github.com/owner/repo/pulls?q=is%3Aopen+label%3Aneeds-merge'
#   resolve-prs.sh '123 118,97'                                 # explicit numbers
#   resolve-prs.sh https://github.com/owner/repo/pull/123
#
# Run it from inside the repo's checkout: label and query forms search the repo
# `gh` resolves for the current directory.
set -euo pipefail

arg="${1:?usage: resolve-prs.sh <label | search query | pulls URL | PR numbers>}"

list() {
  gh pr list --state open --limit 200 --search "$1" --json number,isDraft \
    --jq '.[] | select(.isDraft | not) | .number'
}

if [[ "$arg" =~ ^https?://github\.com/.+[?\&]q= ]]; then
  q=$(python3 -c 'import sys, urllib.parse as u; print(u.parse_qs(u.urlparse(sys.argv[1]).query)["q"][0])' "$arg")
  list "$q"
elif [[ "$arg" =~ /pull/([0-9]+) ]]; then
  echo "${BASH_REMATCH[1]}"
elif [[ "$arg" =~ ^[0-9,\ ]+$ ]]; then
  tr ', ' '\n\n' <<<"$arg" | grep -E '^[0-9]+$'
elif [[ "$arg" == *:* || "$arg" == *" "* ]]; then
  list "$arg"
else
  list "label:$arg"
fi | sort -n | uniq
