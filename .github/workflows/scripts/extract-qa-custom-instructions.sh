#!/usr/bin/env bash
# Extract any custom instructions a user appended to a `/qa-review` PR
# comment so the AI QA workflow can fold them into the agent prompt.
#
# Input: $COMMENT_BODY env var. We use an env var rather than stdin or an
# argv slot because GitHub Actions passes `${{ github.event.comment.body }}`
# safely only through `env:` (argv interpolation is a known injection
# vector). The body may contain newlines, quotes, backslashes — anything a
# user can type in a comment.
#
# Output: the custom-instructions payload to stdout. Empty output means
# "no custom instructions; run the default QA pass".
#
# Matching rules:
#   - Find the first `/qa-review` token followed by either whitespace or
#     end-of-input. This skips longer words like `/qa-reviewing` so they
#     don't accidentally consume the rest of the comment.
#   - Everything from the byte after that token to end-of-input is the
#     payload.
#   - Leading whitespace on the payload (the separator space or newline
#     after `/qa-review`) is stripped. Internal whitespace, blank lines,
#     and trailing whitespace are preserved verbatim — they may be
#     intentional in multi-paragraph instructions.
#
# Tested by extract-qa-custom-instructions.test.sh.

set -uo pipefail

COMMENT_BODY="${COMMENT_BODY:-}"

if [[ -z "${COMMENT_BODY}" ]]; then
  exit 0
fi

# Perl chosen over sed/awk because:
#   - The body is inherently multi-line; sed/awk default to line-by-line
#     handling which makes "find the token then take everything after"
#     awkward.
#   - Bash regex matching does not span newlines.
#   - Perl is in PATH on every GitHub-hosted ubuntu runner.
#
# `-0777` slurps stdin as one string. The regex uses `(?=\s|$)` as a
# lookahead so `/qa-reviewing` doesn't match at that position; the engine
# moves on and (if present) finds a later real `/qa-review` followed by
# whitespace. The `s` flag lets `.` cross newlines.
#
# We pass the body through stdin (not perl's `-e` env) to avoid any
# shell-level interpolation of the user's text. The body env var is fed
# in via a here-string.
perl -0777 -e '
  my $body = <STDIN>;
  if ($body =~ m{/qa-review(?=\s|$)(.*)}s) {
    my $tail = $1;
    $tail =~ s/^[ \t]*//;   # strip horizontal whitespace on the join line
    $tail =~ s/^\n+//;      # then drop leading blank lines
    print $tail;
  }
' <<< "${COMMENT_BODY}"
