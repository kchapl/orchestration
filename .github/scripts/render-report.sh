#!/usr/bin/env bash
#
# Render the cross-repo inventory summary for a workflow run from the JSON
# records written by audit-repo.sh.
#
# Usage:
#   ./.github/scripts/render-report.sh audit-records >> "$GITHUB_STEP_SUMMARY"
#
# The report is advisory: missing or unreadable records produce a note in the
# summary instead of failing the step, so the audit job stays the source of
# truth for pass/fail.

# The jq programs and markdown templates below are literal text, so SC2016
# ("single quotes prevent expansion") is a false positive in this file.
# shellcheck disable=SC2016

set -uo pipefail

dir=${1:-}

shopt -s nullglob
records=()
[[ -n $dir && -d $dir ]] && records=("$dir"/*.json)

if ((${#records[@]} == 0)); then
  printf '## Health check inventory\n\n'
  printf '_No audit records for this run._\n'
  exit 0
fi

if ! all=$(jq -s '.' "${records[@]}"); then
  printf '## Health check inventory\n\n'
  printf '_Audit records for this run could not be read._\n'
  exit 0
fi

total=$(jq 'length' <<<"$all")
flagged=$(jq '[.[] | select(.findings > 0)] | length' <<<"$all")

printf '## Health check inventory\n\n'
printf '`%s` repositories audited, `%s` with actionable findings.\n\n' "$total" "$flagged"

# section <title> <jq filter yielding an array> <jq string template>
section() {
  local title=$1 filter=$2 template=$3 count
  count=$(jq "$filter | length" <<<"$all")
  printf '### %s (%s)\n\n' "$title" "$count"
  if ((count == 0)); then
    printf '_None._\n\n'
    return 0
  fi
  jq -r "$filter"' | .[] | '"$template" <<<"$all"
  printf '\n'
}

section 'Code scanning not enabled' \
  '[.[] | select(.code_scanning == "not_enabled")] | sort_by(.repo)' \
  '"- `\(.repo)`"'

unknown=$(jq '[.[] | select(.code_scanning == "unknown")] | length' <<<"$all")
if ((unknown > 0)); then
  printf '> %s repositories could not be checked for code scanning; see the audit job logs.\n\n' "$unknown"
fi

section 'Candidates for archiving' \
  '[.[] | select(.archival == "candidate")] | sort_by(.repo)' \
  '"- `\(.repo)` — \(if .last_human_commit == "" then "no human-authored commit in the last 100 commits" else "last human commit \((.last_human_commit | split("T")[0]))" end)"'

section 'Unsupported primary language' \
  '[.[] | select(.language_supported == false)] | sort_by(.repo)' \
  '"- `\(.repo)` — `\(.language)`"'
