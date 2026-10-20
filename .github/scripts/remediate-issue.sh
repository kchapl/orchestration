#!/usr/bin/env bash
# Run one OpenHands 1.x remediation for a single repository issue. The CLI
# runs the agent in the checkout itself, so there is no sandbox image to pull
# and no Docker socket to mount.
set -euo pipefail

OPENHANDS_VERSION=${OPENHANDS_VERSION:-1.16.0}
LLM_MODEL=${LLM_MODEL:-gemini/gemini-3.5-flash-lite}
LLM_API_KEY=${LLM_API_KEY:?LLM_API_KEY is required}
REPO=${REPO:?REPO is required}
ISSUE=${ISSUE:?ISSUE is required}
WORKSPACE=${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TARGET="$WORKSPACE/remediation/${REPO//\//__}"
BRANCH="health/fix-issue-$ISSUE"

REMEDIATION_PROMPT="Read .issue-context.md and address all technical vulnerabilities, CodeQL warnings, dependency updates, and GitHub Actions workflow issues mentioned. If the issue reports GitHub Actions that are behind their latest release, update each listed \`uses:\` ref to the version named in that finding (for example @v7.0.1), or to that release's major tag when the ref is a floating major (for example @v7); never move a ref to an older version and never commit SHAs. If the issue reports unpinned workflows, pin those refs to the newest release of the action's current major version (for example @v7), never an older major and never a commit SHA. If the issue reports neither pinning nor version findings, leave workflow files alone. Do not hand-edit .github/workflows/actions.lock: the pipeline runs 'gh actions-lock' after your edits to create or refresh it. If .issue-context.md indicates the repo is an Archival Candidate, ignore routine package updates. Your work is only accepted when CI passes, so read .github/workflows/*.yml and run every command those jobs run -- install, lint, formatter, type checker, and tests -- not just the test suite."

ensure_openhands() {
  export PATH="$HOME/.local/bin:$PATH"
  if command -v openhands >/dev/null 2>&1 &&
    openhands --version 2>/dev/null | grep -qF "$OPENHANDS_VERSION"; then
    return 0
  fi
  if ! command -v uv >/dev/null 2>&1; then
    echo "::error::uv is required to install the OpenHands CLI"
    return 1
  fi
  echo "Installing OpenHands CLI $OPENHANDS_VERSION..."
  uv tool install --force "openhands==$OPENHANDS_VERSION" --python 3.12
}

configure_openhands_agent() {
  local persistence_dir=$1
  local python
  python="$(uv tool dir)/openhands/bin/python"
  if [[ ! -x $python ]]; then
    echo "::error::Could not find the OpenHands tool Python interpreter"
    return 1
  fi

  OPENHANDS_PERSISTENCE_DIR="$persistence_dir" \
    LLM_API_KEY="$LLM_API_KEY" \
    LLM_MODEL="$LLM_MODEL" \
    "$python" "$SCRIPT_DIR/configure-openhands-agent.py"
}

# A per-day quota error cannot clear while this job is alive: the SDK retries,
# the run still fails, and every rerun burns the same exhausted budget. Report
# the limit and the reset hint instead of a generic failure.
report_quota_exhaustion() {
  local log=$1 limit retry
  grep -q 'GenerateRequestsPerDay' "$log" || return 1
  limit=$(grep -om1 -E 'limit: [0-9]+, model: [a-z0-9.-]+' "$log" || true)
  retry=$(grep -om1 -E 'Please retry in [0-9hms.]+' "$log" || true)
  echo "::error::LLM daily quota exhausted for $REPO: ${limit:-$LLM_MODEL}"
  if [[ -n $retry ]]; then
    echo "  $retry"
  fi
  echo "  Daily quotas reset at midnight Pacific. Raise the quota for the"
  echo "  GEMINI_API_KEY project in AI Studio, or point LLM_MODEL at a model with"
  echo "  a larger free-tier daily limit; rerunning now cannot succeed."
  return 0
}

# Opening the pull request is not the end of the job: the target repository's
# own CI has to agree with it. gh pr checks exits non-zero while any check is
# still pending, so read the rollup and classify each entry instead of trusting
# that exit status.
pr_check_rollup() {
  local pr=$1
  gh pr view "$pr" --repo "$REPO" --json statusCheckRollup --jq '
    def bucket:
      if .state == "SUCCESS" or .state == "NEUTRAL" or .state == "SKIPPED" then "ok"
      elif .state == "PENDING" or .state == "EXPECTED"
        or .state == "QUEUED" or .state == "IN_PROGRESS" then "pending"
      else "fail" end;
    [(.statusCheckRollup // [])[]
      | {
          name: (.name // .context // "check"),
          link: (.detailsUrl // .targetUrl // ""),
          state: (if .__typename == "StatusContext" then .state
                  elif .status == "COMPLETED" then .conclusion
                  else "PENDING" end)
        }
      | {name, link, state, bucket: bucket}]
  '
}

wait_for_pr_checks() {
  local pr=$1 timeout=${PR_CHECK_TIMEOUT:-900} interval=${PR_CHECK_INTERVAL:-15}
  local grace=${PR_CHECK_START_GRACE:-120}
  local start=$SECONDS deadline checks total pending failed
  deadline=$((start + timeout))

  while :; do
    if ! checks=$(pr_check_rollup "$pr"); then
      echo "::error::Could not read the checks on $REPO pull request #$pr"
      return 1
    fi
    total=$(jq 'length' <<<"$checks")
    if ((total == 0)); then
      # A repository can take a few seconds to register its first check run,
      # but one without CI never registers any; do not burn the whole budget.
      if (((SECONDS - start) >= grace)); then
        echo "::warning::$REPO pull request #$pr reported no checks; nothing to verify"
        return 0
      fi
      echo "Waiting for checks on $REPO pull request #$pr to be registered..."
      sleep "$interval"
      continue
    fi

    pending=$(jq '[.[] | select(.bucket == "pending")] | length' <<<"$checks")
    if ((pending > 0)); then
      if ((SECONDS >= deadline)); then
        echo "::error::Checks on $REPO pull request #$pr were still running after ${timeout}s"
        jq -r '.[] | select(.bucket == "pending")
          | "  still running: \(.name) \(.link)"' <<<"$checks"
        return 1
      fi
      echo "$pending of $total checks still running on pull request #$pr..."
      sleep "$interval"
      continue
    fi

    failed=$(jq '[.[] | select(.bucket == "fail")] | length' <<<"$checks")
    if ((failed > 0)); then
      echo "::error::$failed of $total checks failed on $REPO pull request #$pr"
      jq -r '.[] | select(.bucket == "fail")
        | "  failed: \(.name) (\(.state)) \(.link)"' <<<"$checks"
      return 1
    fi

    echo "All $total checks passed on $REPO pull request #$pr"
    return 0
  done
}

run_openhands() {
  local log=$1
  local persistence_dir=$2
  (
    cd "$TARGET" || exit 1
    # The token stays out of the agent's environment; the script keeps it for
    # the gh calls before and after this invocation.
    env -u GH_TOKEN -u GITHUB_TOKEN \
      LLM_API_KEY="$LLM_API_KEY" \
      LLM_MODEL="$LLM_MODEL" \
      OPENHANDS_PERSISTENCE_DIR="$persistence_dir" \
      OPENHANDS_SUPPRESS_BANNER=1 \
      openhands --headless --json --override-with-envs -t "$REMEDIATION_PROMPT"
  ) 2>&1 | tee "$log"
}

gh auth setup-git

echo "Checking $REPO (issue #$ISSUE)..."
if ! state=$(gh issue view "$ISSUE" --repo "$REPO" --json state --jq .state); then
  echo "::error::Could not check issue #$ISSUE on $REPO"
  exit 1
fi
if [[ $state != OPEN ]]; then
  echo "Issue #$ISSUE on $REPO is no longer open; skipping."
  exit 0
fi

if ! output=$(git ls-remote --heads "https://github.com/$REPO.git" "$BRANCH"); then
  echo "::error::Could not check branch state for $REPO"
  exit 1
fi
if [[ -n $output ]]; then
  echo "Branch $BRANCH already exists on $REPO; skipping."
  exit 0
fi

ensure_openhands

mkdir -p "$WORKSPACE/remediation"
if ! gh repo clone "$REPO" "$TARGET" -- --depth=1; then
  echo "::error::Could not clone $REPO"
  exit 1
fi

if ! output=$(git -C "$TARGET" ls-remote --heads origin "$BRANCH"); then
  echo "::error::Could not recheck branch state for $REPO"
  exit 1
fi
if [[ -n $output ]]; then
  echo "Branch $BRANCH appeared on $REPO during checkout; skipping."
  exit 0
fi

git -C "$TARGET" checkout -b "$BRANCH"
gh issue view "$ISSUE" --repo "$REPO" --json body --jq .body >"$TARGET/.issue-context.md"

echo "Running OpenHands for $REPO (issue #$ISSUE)..."
persistence_dir=$(mktemp -d)
chmod 700 "$persistence_dir"
trap 'rm -rf -- "$persistence_dir"' EXIT
if ! configure_openhands_agent "$persistence_dir"; then
  echo "::error::Could not configure the OpenHands Gemini agent"
  exit 1
fi
log=$(mktemp)
if ! run_openhands "$log" "$persistence_dir"; then
  report_quota_exhaustion "$log" || true
  rm -f "$log"
  echo "::error::OpenHands remediation failed for $REPO (issue #$ISSUE)"
  exit 1
fi
# The CLI exits 0 even when the conversation ends in an error, so the streamed
# events are the only reliable failure signal.
if grep -qE '"kind"[[:space:]]*:[[:space:]]*"ConversationErrorEvent"' "$log"; then
  if ! report_quota_exhaustion "$log"; then
    echo "::error::OpenHands reported an error while remediating $REPO"
    grep -m 1 -E '"kind"[[:space:]]*:[[:space:]]*"ConversationErrorEvent"' "$log" | cut -c1-800
  fi
  rm -f "$log"
  exit 1
fi
rm -f "$log"

rm -f "$TARGET/.issue-context.md"
if git -C "$TARGET" status --porcelain -- .github/workflows | grep -qE '\.ya?ml$'; then
  echo "Locking GitHub Actions dependencies in $REPO..."
  if ! gh extension list | grep -q 'github/gh-actions-lock'; then
    gh extension install github/gh-actions-lock >/dev/null 2>&1 ||
      echo "::warning::Could not install gh-actions-lock for $REPO"
  fi
  (cd "$TARGET" && gh actions-lock) ||
    echo "::warning::gh actions-lock failed for $REPO; the lockfile may be stale"
fi

if [[ -n $(git -C "$TARGET" status --porcelain) ]]; then
  git -C "$TARGET" config user.name "github-actions[bot]"
  git -C "$TARGET" config user.email "github-actions[bot]@users.noreply.github.com"
  git -C "$TARGET" add -A
  git -C "$TARGET" commit -m "fix(health): automated OpenHands resolution for issue #$ISSUE"
  git -C "$TARGET" push origin "$BRANCH"

  # The body must not claim verification the job has not done; the check gate
  # below is what turns this draft into a verified pull request.
  gh pr create \
    --repo "$REPO" \
    --head "$BRANCH" \
    --title "🤖 [PR] Resolve Health Issue #$ISSUE" \
    --body "### Automated Maintenance Fixes
Generated by OpenHands using **\`${LLM_MODEL#gemini/}\`**.

**Closes #$ISSUE**

**Verification:** the health-check workflow that opened this draft waits for
every check on this pull request and fails its own run if any of them fails.
A failing check here therefore means the remediation is unfinished, not that
CI is flaky. Please inspect the diff before approving." \
    --draft

  if ! pr=$(gh pr view "$BRANCH" --repo "$REPO" --json number --jq .number); then
    echo "::error::Opened a pull request for $BRANCH but could not read its number"
    exit 1
  fi
  echo "Opened https://github.com/$REPO/pull/$pr"
  wait_for_pr_checks "$pr"
  if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
    printf '### %s\n\nPull request #%s for issue #%s passed every check.\n' \
      "$REPO" "$pr" "$ISSUE" >>"$GITHUB_STEP_SUMMARY"
  fi
else
  echo "OpenHands completed without generating code diffs for issue #$ISSUE on $REPO."
fi
