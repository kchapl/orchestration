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
    in_wf && /^[[:space:]]+-[[:space:]]+/ {
      pin = $0
      sub(/^[[:space:]]+-[[:space:]]+/, "", pin)
      gsub(/["\047]/, "", pin)
      print wf "\t" pin
      next
    }
    in_wf && /^[[:space:]]+[^[:space:]-][^:]*:[[:space:]]*$/ {
      wf = $0
      sub(/^[[:space:]]+/, "", wf)
      sub(/:[[:space:]]*$/, "", wf)
      gsub(/["\047]/, "", wf)
      print wf "\t"
    }
  ' "$1"
}

# Flatten the dependency section of actions.lock into "<pin key>\t<commit>"
# lines, with the sha1- prefix stripped, so a commit pin can be traced back to
# the ref it was locked from.
lockfile_commit_map() {
  awk '
    /^dependencies:[[:space:]]*$/ { in_deps = 1; next }
    /^[^[:space:]]/ { in_deps = 0 }
    !in_deps { next }
    /^[[:space:]]+[^[:space:]-][^:]*:[[:space:]]*$/ {
      key = $0
      sub(/^[[:space:]]+/, "", key)
      sub(/:[[:space:]]*$/, "", key)
      gsub(/["\047]/, "", key)
      next
    }
    /^[[:space:]]+commit:/ {
      commit = $0
      sub(/^[[:space:]]+commit:[[:space:]]*/, "", commit)
      gsub(/["\047]/, "", commit)
      sub(/^sha1-/, "", commit)
      if (key != "") print key "\t" commit
    }
  ' "$1"
}

# Every external "uses:" reference, as "<workflow path>\t<line>\t<ref>" lines.
# Local paths, docker:// images, and expression-based refs are not versioned
# actions, so both workflow sensors ignore them.
# Only workflow YAML is scanned: a .github/workflows/*.md file is an agentic
# workflow source whose steps are compiled into its .lock.yml, and the lock file
# is what Actions executes and what these sensors must judge.
workflow_uses() {
  local wf_dir="$TARGET_DIR/.github/workflows" hit file rest lineno text uses rel
  [[ -d $wf_dir ]] || return 0

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
    printf '%s\t%s\t%s\n' "$rel" "$lineno" "$uses"
  done < <(grep -rInE --include='*.yml' --include='*.yaml' \
    '^[[:space:]]*(-[[:space:]]+)?uses:' "$wf_dir" 2>/dev/null)
}

# Flags "uses:" references that are not pinned: either a full commit SHA, or a
# ref covered by the official workflow lockfile (.github/workflows/actions.lock).
sensor_actions_pinning() {
  local rel lineno uses key ref reason lock_map=""

  if [[ -f $TARGET_DIR/.github/workflows/actions.lock ]]; then
    lock_map="$WORKDIR/lockfile-map"
    lockfile_map "$TARGET_DIR/.github/workflows/actions.lock" >"$lock_map"
  fi

  while IFS=$'\t' read -r rel lineno uses; do
    if [[ -n $lock_map ]] && grep -Fxq "$rel"$'\t' "$lock_map"; then
      # Onboarded workflow: the runner executes the locked commit, so the ref in
      # the workflow only has to be present in the lockfile for this workflow.
      # gh actions-lock lowercases pin keys, so compare them case-insensitively.
      key=$(printf '%s' "${uses%@*}" | cut -d/ -f1-2 | tr '[:upper:]' '[:lower:]')"@""${uses##*@}"
      grep -Fxiq "$rel"$'\t'"$key" "$lock_map" && continue
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
  done < <(workflow_uses)
}

# Parse a release tag like "v7.0.1" into "7.0.1". Branch names and other refs
# that carry no version fail, so they are simply not version-checked.
parse_action_version() { # <tag>
  local core=${1#v}
  core=${core%%[-+]*}
  [[ $core =~ ^([0-9]+)(\.([0-9]+))?(\.([0-9]+))?$ ]] || return 1
  printf '%s.%s.%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[3]:-0}" "${BASH_REMATCH[5]:-0}"
}

# Latest published tag for an action, cached for the run. Releases are preferred
# because a tag can exist without being announced; actions that publish only
# tags fall back to the highest semver tag. Returns 3 when the action exposes no
# version at all (a private or local action, or date-only tags), which is not a
# sensor failure, and 1 for a real API error.
action_latest_tag() { # <owner/repo>
  local slug=$1 cache="$WORKDIR/action-latest" file out tag
  file="$cache/${slug//\//__}"
  if [[ -s $file ]]; then
    cat "$file"
    return 0
  fi
  mkdir -p "$cache" || return 1

  if out=$(gh api "repos/$slug/releases/latest" --jq '.tag_name // ""' 2>&1); then
    tag=$out
  else
    [[ $out == *"HTTP 404"* ]] || {
      printf '%s\n' "${out%%$'\n'*}" >&2
      return 1
    }
    tag=""
  fi

  if ! [[ $tag =~ ^v?[0-9] ]]; then
    if ! out=$(gh api "repos/$slug/tags?per_page=100" --jq '.[].name' 2>&1); then
      [[ $out == *"HTTP 404"* ]] && return 3
      printf '%s\n' "${out%%$'\n'*}" >&2
      return 1
    fi
    # sort -V keeps 1.10.0 above 1.9.0; prerelease tags are not "latest".
    tag=$(printf '%s\n' "$out" | grep -E '^v?[0-9]+(\.[0-9]+){0,2}$' | sort -V | tail -n 1)
  fi
  [[ -n $tag ]] || return 3
  printf '%s' "$tag" >"$file"
  printf '%s' "$tag"
}

# Flags "uses:" refs that resolve to an older release than the action's latest.
# A floating major tag (@v7) tracks its own major line, so it is only behind once
# the action moves to a newer major; a full version must be the newest release.
# Commit pins are resolved through actions.lock, so SHA-pinned workflows are
# checked as well; an unresolvable pin is skipped rather than guessed at.
sensor_actions_versions() {
  local rel lineno uses key slug ref used latest used_v latest_v note pin rc
  local failures=0 checked=0 lock="$TARGET_DIR/.github/workflows/actions.lock"
  local u_major u_minor u_patch l_major l_minor l_patch
  local -A locations=() pinned_ref=()
  local -a order=()

  if [[ -f $lock ]]; then
    while IFS=$'\t' read -r key ref; do
      [[ -n $ref ]] && pinned_ref["$ref"]=${key##*@}
    done < <(lockfile_commit_map "$lock")
  fi

  while IFS=$'\t' read -r rel lineno uses; do
    if [[ -n ${locations[$uses]:-} ]]; then
      locations[$uses]+=", $rel:$lineno"
    else
      locations[$uses]="$rel:$lineno"
      order+=("$uses")
    fi
  done < <(workflow_uses)
  ((${#order[@]})) || return 0

  for uses in "${order[@]}"; do
    key=${uses%@*}
    ref=${uses##*@}
    # Reusable workflows are versioned by their repository's own scheme, which
    # need not follow its releases; do not judge them against a release tag.
    [[ $key == */.github/workflows/* ]] && continue
    slug=$(cut -d/ -f1-2 <<<"$key")
    [[ -n $slug ]] || continue
    used=$ref
    if [[ $ref =~ ^[0-9a-f]{40}$ ]]; then
      used=${pinned_ref[$ref]:-}
      [[ -n $used ]] || continue
    fi
    used_v=$(parse_action_version "$used") || continue

    if latest=$(action_latest_tag "$slug"); then
      :
    else
      rc=$?
      ((rc == 3)) && continue
      failures=$((failures + 1))
      continue
    fi
    checked=$((checked + 1))
    latest_v=$(parse_action_version "$latest") || continue

    IFS=. read -r u_major u_minor u_patch <<<"$used_v"
    IFS=. read -r l_major l_minor l_patch <<<"$latest_v"
    note=""
    if ((u_major < l_major)); then
      if ((l_major - u_major == 1)); then
        note="1 major version behind"
      else
        note="$((l_major - u_major)) major versions behind"
      fi
    elif ((u_major == l_major)) && ! [[ $used =~ ^v?[0-9]+$ ]]; then
      # A major-only tag floats, so only compare full versions within a major.
      if ((u_minor < l_minor)) || ((u_minor == l_minor && u_patch < l_patch)); then
        note="an older $l_major.x release"
      fi
    fi
    if [[ -n $note ]]; then
      pin=""
      [[ $ref =~ ^[0-9a-f]{40}$ ]] && pin=" (pinned at \`$used\`)"
      # shellcheck disable=SC2016 # literal Markdown backticks in the issue body
      printf -- '- `%s`%s is %s; latest is `%s` (`%s`)\n' \
        "$uses" "$pin" "$note" "$latest" "${locations[$uses]}" \
        >>"$WORKDIR/actions-versions"
    fi
  done

  if ((failures > 0)); then
    printf 'could not read the latest release for %d action(s)\n' "$failures" >&2
    return 1
  fi
  ((checked > 0)) || return 3
  return 0
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
  local dep_n code_n loc_n act_n ver_n

  dep_n=$(count_lines "$WORKDIR/dependabot")
  code_n=$(count_lines "$WORKDIR/codeql")
  loc_n=$(count_lines "$WORKDIR/local")
  act_n=$(count_lines "$WORKDIR/actions")
  ver_n=$(count_lines "$WORKDIR/actions-versions")

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
  print_section "$WORKDIR/actions" "Every \`uses:\` ref is a commit SHA or is covered by \`actions.lock\`."
  printf '\n#### GitHub Actions versions (%s)\n\n' "$ver_n"
  print_section "$WORKDIR/actions-versions" "Every \`uses:\` ref is on the latest release of its action."

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
for s in dependabot codeql local local-npm local-pip actions actions-versions warnings \
  language archival dependabot_note codeql_note; do : >"$WORKDIR/$s"; done
for s in dependabot codeql language archival npm-audit pip-audit actions-pinning \
  actions-versions; do
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
run_sensor "actions versions" sensor_actions_versions >"$WORKDIR/log-actions-versions" 2>&1 & pid_action_versions=$!
wait "$pid_npm_audit" || true
wait "$pid_pip_audit" || true
wait "$pid_actions" || true
wait "$pid_action_versions" || true

for s in dependabot codeql language archival npm-audit pip-audit actions-pinning actions-versions; do
  cat "$WORKDIR/log-$s"
done
for s in dependabot codeql language archival npm-audit pip-audit actions-pinning actions-versions; do
  cat "$WORKDIR/warning-$s" >>"$WORKDIR/warnings"
done
cat "$WORKDIR/local-npm" "$WORKDIR/local-pip" >"$WORKDIR/local"

BODY=$(render_body)
FINDINGS=$(( $(count_lines "$WORKDIR/dependabot") + $(count_lines "$WORKDIR/codeql") \
  + $(count_lines "$WORKDIR/local") + $(count_lines "$WORKDIR/actions") \
  + $(count_lines "$WORKDIR/actions-versions") \
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
