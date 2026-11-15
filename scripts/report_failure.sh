#!/bin/sh
# Opens an issue with the errors from a failed CI step, so they can be read without the Actions log viewer.
# usage: sh scripts/report_failure.sh "<what failed>" <log file>...
set -u
what=$1
shift
short=$(printf %s "$GITHUB_SHA" | cut -c1-7)
{
    echo "**$what** failed on \`$short\` (branch \`$GITHUB_REF_NAME\`)."
    echo
    echo "Run: $GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
    echo
    echo '```'
    for log in "$@"; do
        [ -f "$log" ] || continue
        echo "== $log"
        if grep -qE "error:|fatal error|failed \(" "$log"; then
            grep -nE -A3 "error:|fatal error|Test Case .* failed" "$log" | head -c 30000
        else
            tail -n 60 "$log"
        fi
    done
    echo '```'
} > failure.md
gh issue create --repo "$GITHUB_REPOSITORY" --title "CI: $what failed on $short" --body-file failure.md
