#!/usr/bin/env bash
#
# Phase 1 of the two-phase polyglot health check.
#
# Audits a single repository checkout, then creates or updates the
# "automated-health" tracking issue when actionable findings exist.
#
# Design rule: a sensor must never be able to stop the audit. Each sensor runs
# in isolation; if it fails (missing tool, API error, disabled feature) the
# failure is surfaced as a warning annotation plus a line in the issue body, and
# the remaining sensors still run. Findings, not sensor health, decide whether
# an issue is raised.
#
# Usage:
#   REPO=owner/name ./.github/scripts/audit-repo.sh
#   REPO=owner/name TARGET_DIR=/path/to/checkout ./.github/scripts/audit-repo.sh
#   REPO=owner/name DRY_RUN=1 ./.github/scripts/audit-repo.sh   # print body only
#
# Environment:
#   REPO        owner/name being audited (required)
#   TARGET_DIR  checkout to inspect (default: current working directory)
#   GH_TOKEN    token for API calls and issue writes (required unless DRY_RUN=1)
#   DRY_RUN     1 = print the issue body and exit without touching GitHub
#   AUDIT_RECORD_DIR  when set, write a JSON inventory record for this repo
#                     into that directory (consumed by render-report.sh)

set -uo pipefail

LABEL="automated-health"
ISSUE_TITLE="🛡️ [Health Audit] Security Vulnerabilities & Dependency Maintenance"
SUPPORTED_LANGUAGES="Python Shell TypeScript Scala JavaScript Unspecified"

REPO=${REPO:-}
TARGET_DIR=${TARGET_DIR:-$PWD}
DRY_RUN=${DRY_RUN:-0}
AUDIT_RECORD_DIR=${AUDIT_RECORD_DIR:-}

WORKDIR=""
cleanup() { [[ -n $WORKDIR ]] && rm -rf "$WORKDIR"; }
trap cleanup EXIT

log()  { printf '%s\n' "$*"; }
warn() { printf '::warning::%s\n' "$*"; }
fail() { printf '::error::%s\n' "$*"; printf 'error: %s\n' "$*" >&2; exit 1; }

# Run a sensor function, converting a non-zero exit into a warning instead of
# aborting the audit. Sensors write their findings to $WORKDIR/<name>.
#
# Exit codes: 0 = done, 3 = sensor does not apply to this repo (feature not
# enabled), anything else = genuine sensor failure.
run_sensor() {
  local name=$1 fn=$2 rc=0 err
  local warning_key=${1// /-}
  warning_key=${warning_key//\//-}
  local warning_file="$WORKDIR/warning-$warning_key"
  err=$("$fn" 2>&1 >/dev/null) || rc=$?
  if ((rc == 0)); then
    log "  ok    $name"
    return 0
  fi
  err=${err//$'\n'/; }
  if ((rc == 3)); then
    log "  skip  $name (${err:-not applicable to this repository})"
    return 0
  fi
  warn "$name sensor failed: ${err:-no details}"
  printf -- '- **%s**: sensor failed — %s\n' "$name" "${err:-no details}" >"$warning_file"
}

capitalize() { local first=${1:0:1}; printf '%s%s' "${first^^}" "${1:1}"; }

# Record this repo's inventory state for the run summary. Advisory only: a
# failure here must never fail the audit.
write_record() {
  [[ -n $AUDIT_RECORD_DIR ]] || return 0
  mkdir -p "$AUDIT_RECORD_DIR" 2>/dev/null || return 1
  jq -n \
    --arg repo "$REPO" \
    --arg language "$(<"$WORKDIR/language_name")" \
    --arg language_ok "$(<"$WORKDIR/language_ok")" \
    --arg code_scanning "$(<"$WORKDIR/code_scanning")" \
    --arg archival "$(<"$WORKDIR/archival_state")" \
    --arg last_human "$(<"$WORKDIR/archival_date")" \
    --argjson findings "$FINDINGS" \
    '{
      repo: $repo,
      language: $language,
      language_supported: ($language_ok | if . == "true" then true elif . == "false" then false else null end),
      code_scanning: $code_scanning,
      archival: $archival,
      last_human_commit: $last_human,
      findings: $findings
    }' >"$AUDIT_RECORD_DIR/${REPO//\//__}.json"
}

# Classify a gh api failure. Prints a human-readable reason and returns:
#   3 = the feature is not enabled / has no data (404), which is not a fault
#   0 = a real failure worth warning about
gh_error_reason() { # <stderr from gh> <feature name>
  local err=$1 feature=$2
  if [[ $err == *"HTTP 404"* || $err == *"no analysis found"* ]]; then
    printf '%s is not enabled for this repository, or has no analyses yet.' "$feature"
    return 3
  fi
  if [[ $err == *"HTTP 403"* || $err == *"Resource not accessible"* || $err == *"scope"* ]]; then
    printf 'the token cannot read %s. Grant "security_events" (classic PAT) or the matching read permission on a fine-grained PAT.' "$feature"
    return 0
  fi
  printf '%s' "${err%%$'\n'*}"
  return 0
}

# ---------------------------------------------------------------------------
# Sensors
# ---------------------------------------------------------------------------

sensor_dependabot() {
  local out reason status
  if ! out=$(gh api --paginate --jq \
    '.[] | "- **\(.security_advisory.severity | ascii_upcase)** \(.security_vulnerability.package.name) — \(.security_advisory.summary) ([alert #\(.number)](\(.html_url)))"' \
    "repos/$REPO/dependabot/alerts?state=open&per_page=100" 2>&1); then
    reason=$(gh_error_reason "$out" "Dependabot alerts")
    status=$?
    if ((status == 3)); then
      printf '_%s_\n' "$(capitalize "$reason")" >"$WORKDIR/dependabot_note"
      printf '%s\n' "$reason" >&2
      return 3
    fi
    printf '%s\n' "$reason" >&2
    return 1
  fi
  printf '%s\n' "$out" | sed '/^$/d' >"$WORKDIR/dependabot"
}

sensor_codeql() {
  local out reason status
  if ! out=$(gh api --paginate --jq \
    '.[] | "- **\(.rule.severity // .rule.security_severity_level // "warning")** \(.rule.id) — \(.rule.description) (\(.most_recent_instance.location.path // "unknown path"))"' \
    "repos/$REPO/code-scanning/alerts?state=open&per_page=100" 2>&1); then
    reason=$(gh_error_reason "$out" "code scanning")
    status=$?
    if ((status == 3)); then
      printf 'not_enabled' >"$WORKDIR/code_scanning"
      printf '_%s_\n' "$(capitalize "$reason")" >"$WORKDIR/codeql_note"
      printf '%s\n' "$reason" >&2
      return 3
    fi
    printf '%s\n' "$reason" >&2
    return 1
  fi
  printf 'enabled' >"$WORKDIR/code_scanning"
  printf '%s\n' "$out" | sed '/^$/d' >"$WORKDIR/codeql"
}

sensor_language() {
  local lang
  lang=$(gh api "repos/$REPO" --jq '.language // "Unspecified"') || {
    printf 'repository metadata request failed\n' >&2
    return 1
  }
  printf '%s' "$lang" >"$WORKDIR/language_name"
  case " $SUPPORTED_LANGUAGES " in
  *" $lang "*)
    printf 'true' >"$WORKDIR/language_ok"
    return 0
    ;;
  esac
  printf 'false' >"$WORKDIR/language_ok"
  printf "> **⚠️ Unsupported primary language:** \`%s\` is outside the supported set (%s). Remediation can still edit files, but native test suites may need a custom toolchain.\n" \
    "$lang" "${SUPPORTED_LANGUAGES// /, }" >"$WORKDIR/language"
}

sensor_archival() {
  local last cutoff ts
  last=$(gh api "repos/$REPO/commits?per_page=100" --jq '
    [ .[]
      | select((.author.type? // "") == "User")
      | select(((.author.login? // "") | ascii_downcase | contains("bot")) | not)
    ] | (.[0].commit.committer.date // "")') || {
    printf 'commit history request failed\n' >&2
    return 1
  }
  cutoff=$(($(date -u +%s) - 365 * 24 * 3600))

  if [[ -z $last || $last == null ]]; then
    printf 'candidate' >"$WORKDIR/archival_state"
    printf "> **📦 Archival candidate:** no human-authored commit in the last 100 commits. Consider \`gh repo archive %s\`.\n" \
      "$REPO" >"$WORKDIR/archival"
    return 0
  fi

  ts=$(date -u -d "$last" +%s 2>/dev/null) || {
    printf 'unparsable commit date: %s\n' "$last" >&2
    return 1
  }
  printf '%s' "$last" >"$WORKDIR/archival_date"
  if ((ts < cutoff)); then
    printf 'candidate' >"$WORKDIR/archival_state"
    printf "> **📦 Archival candidate:** last human commit was %s (over a year ago). Consider \`gh repo archive %s\`.\n" \
      "${last%%T*}" "$REPO" >"$WORKDIR/archival"
  else
    printf 'active' >"$WORKDIR/archival_state"
  fi
}

# npm audit needs a lockfile; without one it just errors out.
sensor_npm_audit() {
  [[ -f "$TARGET_DIR/package-lock.json" || -f "$TARGET_DIR/npm-shrinkwrap.json" ]] || return 0

  local json total rendered
  if ! command -v npm >/dev/null 2>&1; then
    printf 'npm not available on PATH\n' >&2
    return 1
  fi
  # npm audit exits non-zero whenever vulnerabilities exist, so ignore its status
  # and judge by the JSON payload instead.
  json=$(cd "$TARGET_DIR" && npm audit --json 2>/dev/null) || true
  total=$(jq -r '.metadata.vulnerabilities.total // 0' <<<"$json" 2>/dev/null) || total=""
  if ! [[ $total =~ ^[0-9]+$ ]]; then
    printf 'could not parse npm audit output (lockfile out of sync?)\n' >&2
    return 1
  fi
  ((total > 0)) || return 0

  if ! rendered=$(jq -r '.vulnerabilities // {} | to_entries[]
      | select((.value.severity // "unknown") != "info")
      | "- **\(.value.severity | ascii_upcase)** \(.key) — \(.value.via[0] | if type == "object" then (.title // "advisory") else . end)"' <<<"$json"); then
    printf 'could not render npm audit findings\n' >&2
    return 1
  fi
  [[ -n $rendered ]] && printf '%s\n' "$rendered" >>"$WORKDIR/local-npm"
  return 0
}

# pip-audit reports a list of packages; only entries with vulns are findings.
sensor_pip_audit() {
  local manifests=() f out count rendered
  for f in "$TARGET_DIR"/requirements*.txt; do
    [[ -f $f ]] && manifests+=("$f")
  done
  ((${#manifests[@]})) || return 0

  if ! command -v pip-audit >/dev/null 2>&1; then
    if ! python3 -m pip install --quiet --disable-pip-version-check pip-audit >/dev/null 2>&1; then
      printf 'pip-audit unavailable and could not be installed\n' >&2
      return 1
    fi
  fi

  for f in "${manifests[@]}"; do
    out=$(pip-audit -r "$f" --format=json 2>/dev/null) || true
    count=$(jq -r '[.[] | (.vulns // [])[]] | length' <<<"$out" 2>/dev/null) || count=""
    if ! [[ $count =~ ^[0-9]+$ ]]; then
      printf 'could not parse pip-audit output for %s\n' "${f#"$TARGET_DIR"/}" >&2
      return 1
    fi
    ((count > 0)) || continue

    if ! rendered=$(jq -r '.[] | select((.vulns // []) | length > 0) | .vulns[]
        | "- **PYTHON** \(if (.fix_versions // []) | length > 0 then "fix: \(.fix_versions | join(", "))" else "no fix available" end) — \(.id): \(.description | split("\n")[0])"' <<<"$out"); then
      printf 'could not render pip-audit findings for %s\n' "${f#"$TARGET_DIR"/}" >&2
      return 1
    fi
    [[ -n $rendered ]] && printf '%s\n' "$rendered" >>"$WORKDIR/local-pip"
  done
  return 0
}

# Flatten .github/workflows/actions.lock into "<workflow path>\t<pin key>" lines,
# plus a bare "<workflow path>\t" line for every onboarded workflow.
# Pin keys are OWNER/REPO@REF, so a uses: owner/repo/sub@ref maps onto one.
lockfile_map() {
  awk '
    /^workflows:[[:space:]]*$/ { in_wf = 1; wf = ""; next }
    /^[^[:space:]]/ { in_wf = 0 }
    in_wf && /^  [^[:space:]-][^:]*:[[:space:]]*$/ {
      wf = $0
      sub(/:[[:space:]]*$/, "", wf)
      wf = substr(wf, 3)
      print wf "\t"
      next
    }
    in_wf && /^[[:space:]]+-[[:space:]]+/ {
      pin = $0
      sub(/^[[:space:]]+-[[:space:]]+/, "", pin)
      print wf "\t" pin
    }
  ' "$1"
}

# Flags "uses:" references that are not pinned: either a full commit SHA, or a
# ref covered by the official workflow lockfile (.github/workflows/actions.lock).
sensor_actions_pinning() {
  local wf_dir="$TARGET_DIR/.github/workflows" hit file rest lineno text uses ref reason
  local rel key lock_map=""
  [[ -d $wf_dir ]] || return 0

  if [[ -f $wf_dir/actions.lock ]]; then
    lock_map="$WORKDIR/lockfile-map"
    lockfile_map "$wf_dir/actions.lock" >"$lock_map"
  fi

  while IFS= read -r hit; do
    file=${hit%%:*}
    rest=${hit#*:}
    lineno=${rest%%:*}
    text=${rest#*:}
    uses=${text#*uses:}
    uses=${uses%%#*}
    uses=${uses//[[:space:]]/}
    [[ -z $uses || $uses == ./* || $uses == docker://* || $uses == '$/'* ]] && continue
    # shellcheck disable=SC2016 # literal GitHub Actions expression syntax
    [[ $uses == *'${{'* ]] && continue

    rel=${file#"$TARGET_DIR"/}
    if [[ -n $lock_map ]] && grep -Fxq "$rel"$'\t' "$lock_map"; then
      # Onboarded workflow: the runner executes the locked commit, so the ref in
      # the workflow only has to be present in the lockfile for this workflow.
      key=$(printf '%s' "${uses%@*}" | cut -d/ -f1-2)"@""${uses##*@}"
      grep -Fxq "$rel"$'\t'"$key" "$lock_map" && continue
      reason="not in actions.lock for this workflow (run 'gh actions-lock')"
    elif [[ $uses != *@* ]]; then
      reason="no ref specified"
    else
      ref=${uses##*@}
      [[ $ref =~ ^[0-9a-f]{40}$ ]] && continue
      if [[ -n $lock_map ]]; then
        reason="ref '${ref}' is not a commit SHA and the workflow is not onboarded to actions.lock"
      else
        reason="ref '${ref}' is not a commit SHA"
      fi
    fi
    printf -- "- \`%s:%s\` — \`%s\` (%s)\n" "$rel" "$lineno" "$uses" "$reason" \
      >>"$WORKDIR/actions"
  done < <(grep -rInE '^[[:space:]]*(-[[:space:]]+)?uses:' "$wf_dir" 2>/dev/null)
}

# ---------------------------------------------------------------------------
# Issue body
# ---------------------------------------------------------------------------

count_lines() { local n; n=$(grep -c . "$1" 2>/dev/null); [[ $n =~ ^[0-9]+$ ]] && printf '%s' "$n" || printf '0'; }

print_section() { # <findings file> <fallback text> [note file]
  if [[ -s $1 ]]; then
    cat "$1"
  elif [[ -n ${3:-} && -s $3 ]]; then
    cat "$3"
  else
    printf '%s\n' "$2"
  fi
}

render_body() {
  local dep_n code_n loc_n act_n

  dep_n=$(count_lines "$WORKDIR/dependabot")
  code_n=$(count_lines "$WORKDIR/codeql")
  loc_n=$(count_lines "$WORKDIR/local")
  act_n=$(count_lines "$WORKDIR/actions")

  printf '### 🛡️ Automated Repository Health Audit Findings\n\n'
  printf 'Repository: **%s**\n\n' "$REPO"

  if [[ -s $WORKDIR/language ]]; then cat "$WORKDIR/language"; printf '\n'; fi
  if [[ -s $WORKDIR/archival ]]; then cat "$WORKDIR/archival"; printf '\n'; fi

  printf '#### Dependabot alerts (%s)\n\n' "$dep_n"
  print_section "$WORKDIR/dependabot" 'No open Dependabot alerts.' "$WORKDIR/dependabot_note"
  printf '\n#### Code scanning alerts (%s)\n\n' "$code_n"
  print_section "$WORKDIR/codeql" 'No open code scanning alerts.' "$WORKDIR/codeql_note"
  printf '\n#### Dependency audit findings (%s)\n\n' "$loc_n"
  print_section "$WORKDIR/local" 'No vulnerable dependencies detected by local audits.'
  printf '\n#### GitHub Actions pinning (%s)\n\n' "$act_n"
  print_section "$WORKDIR/actions" "All \`uses:\` references are pinned to commit SHAs."

  if [[ -s $WORKDIR/warnings ]]; then
    printf '\n#### Sensor warnings\n\n'
    printf '> These sensors could not complete. Their sections above may be incomplete.\n\n'
    cat "$WORKDIR/warnings"
  fi

  printf '\n---\n'
  printf '<sub>Generated by the two-phase health check. Phase 2 may open a draft PR against this issue; close it to opt out.</sub>\n'
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

[[ -n $REPO ]] || fail "REPO is not set (expected owner/name)"
[[ -d $TARGET_DIR ]] || fail "TARGET_DIR '$TARGET_DIR' is not a directory"
[[ $DRY_RUN == 1 ]] || command -v gh >/dev/null 2>&1 || fail "gh CLI is not installed"

WORKDIR=$(mktemp -d) || fail "could not create a temp directory"
for s in dependabot codeql local local-npm local-pip actions warnings language archival \
  dependabot_note codeql_note; do : >"$WORKDIR/$s"; done
for s in dependabot codeql language archival npm-audit pip-audit actions-pinning; do
  : >"$WORKDIR/log-$s"
  : >"$WORKDIR/warning-$s"
done
# Inventory state surfaced in the run summary, kept separate from findings.
printf 'unknown' >"$WORKDIR/code_scanning"
printf 'unknown' >"$WORKDIR/archival_state"
printf '' >"$WORKDIR/language_name"
printf 'unknown' >"$WORKDIR/language_ok"
printf '' >"$WORKDIR/archival_date"

if [[ $DRY_RUN != 1 ]]; then
  gh api user --jq .login >/dev/null 2>&1 ||
    fail "GitHub authentication failed; refusing to report a clean audit"
fi

log "Auditing $REPO (checkout: $TARGET_DIR)"
# Run no more than four sensors at once to reduce wall time without creating
# unbounded API requests. Each sensor has isolated output files.
run_sensor "dependabot" sensor_dependabot >"$WORKDIR/log-dependabot" 2>&1 & pid_dependabot=$!
run_sensor "codeql" sensor_codeql >"$WORKDIR/log-codeql" 2>&1 & pid_codeql=$!
run_sensor "language" sensor_language >"$WORKDIR/log-language" 2>&1 & pid_language=$!
run_sensor "archival" sensor_archival >"$WORKDIR/log-archival" 2>&1 & pid_archival=$!
wait "$pid_dependabot" || true
wait "$pid_codeql" || true
wait "$pid_language" || true
wait "$pid_archival" || true

run_sensor "npm audit" sensor_npm_audit >"$WORKDIR/log-npm-audit" 2>&1 & pid_npm_audit=$!
run_sensor "pip-audit" sensor_pip_audit >"$WORKDIR/log-pip-audit" 2>&1 & pid_pip_audit=$!
run_sensor "actions pinning" sensor_actions_pinning >"$WORKDIR/log-actions-pinning" 2>&1 & pid_actions=$!
wait "$pid_npm_audit" || true
wait "$pid_pip_audit" || true
wait "$pid_actions" || true

for s in dependabot codeql language archival npm-audit pip-audit actions-pinning; do
  cat "$WORKDIR/log-$s"
done
for s in dependabot codeql language archival npm-audit pip-audit actions-pinning; do
  cat "$WORKDIR/warning-$s" >>"$WORKDIR/warnings"
done
cat "$WORKDIR/local-npm" "$WORKDIR/local-pip" >"$WORKDIR/local"

BODY=$(render_body)
FINDINGS=$(( $(count_lines "$WORKDIR/dependabot") + $(count_lines "$WORKDIR/codeql") \
  + $(count_lines "$WORKDIR/local") + $(count_lines "$WORKDIR/actions") \
  + $(count_lines "$WORKDIR/language") + $(count_lines "$WORKDIR/archival") ))

write_record || warn "could not write the audit record for $REPO"

if ((FINDINGS == 0)); then
  log "No actionable findings for $REPO; no issue raised."
  exit 0
fi

log "Detected $FINDINGS finding(s) for $REPO."

if [[ $DRY_RUN == 1 ]]; then
  printf '%s\n' "$BODY"
  exit 0
fi

if gh label create "$LABEL" --repo "$REPO" \
  --description "Tracked by automated health-check pipeline" \
  --color "0E8A16" --force >/dev/null 2>&1; then
  LABEL_ARGS=(--label "$LABEL")
else
  warn "could not create '$LABEL' label on $REPO; creating the issue without it"
  LABEL_ARGS=()
fi

existing=$(gh issue list --repo "$REPO" --label "$LABEL" --state open \
  --json number --jq '.[0].number // empty' 2>/dev/null) || existing=""

if [[ -z $existing ]]; then
  log "Opening a new health issue on $REPO..."
  gh issue create --repo "$REPO" --title "$ISSUE_TITLE" --body "$BODY" \
    "${LABEL_ARGS[@]}" || fail "issue creation failed for $REPO"
else
  current=$(gh issue view "$existing" --repo "$REPO" --json body --jq '.body' 2>/dev/null) || current=""
  if [[ $current == "$BODY" ]]; then
    log "Issue #$existing on $REPO is already up to date."
  else
    log "Updating issue #$existing on $REPO..."
    gh issue edit "$existing" --repo "$REPO" --body "$BODY" ||
      fail "issue update failed for $REPO"
  fi
fi
