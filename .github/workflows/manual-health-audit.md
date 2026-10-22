---
emoji: "🩺"
description: "On-demand audit of every owned repository that raises or refreshes its automated-health issue."
intent: "Keep repository security, dependency, and workflow findings visible on demand: deterministic sensors do the audit, the agent publishes the results."
labels: ["automation", "security", "maintenance"]

on:
  workflow_dispatch:
    inputs:
      repos:
        description: "Comma-separated owner/name repositories to audit (blank = discover every non-archived, non-fork repository)"
        required: false
        type: string
      limit:
        description: "Maximum number of repositories to audit in this run (0 = no cap)"
        required: false
        type: string
        default: "0"

# One run publishes the same per-repository issues, so queue manual runs rather
# than letting two of them audit and rewrite the same issues at once.
concurrency:
  group: manual-health-audit
  cancel-in-progress: false
  # The group above serializes the audit, but each dispatch still needs its own
  # conclusion slot; without the discriminator a queued run's conclusion waits
  # on the previous run's.
  job-discriminator: ${{ github.run_id }}

permissions:
  contents: read
  issues: read

# Agy (the native Antigravity CLI) only exposes Gemini 3.8/3.7/3.6 Flash and
# 3.1 Pro, with no Flash-Lite slug in any release gh-aw can install. Keep the
# Flash-Lite model the pipeline already runs on by using the Gemini engine.
engine:
  id: gemini
  model: gemini-3.5-flash-lite
  version: "0.64.0"

# AWF v0.28.73 stages the Gemini CLI system settings under /etc/awf, a
# root-owned path the CLI accepts. The compiler's default v0.28.57 writes them
# under $HOME/.awf, which Gemini CLI 0.64.0 rejects as insecure, so the run
# exits 41 with "Invalid auth method selected" before inference.
sandbox:
  agent:
    id: awf
    version: v0.28.73
    # The compiler's digest table only covers its bundled version, so every
    # role this workflow uses is pinned here from the v0.28.73 containers.txt.
    images:
      agent: ghcr.io/github/gh-aw-firewall/agent:0.28.73@sha256:3904bccb0693f73bc19fb8a82d5c9cd95040ae96d99e881967f8ca212d9d6a1a
      api-proxy: ghcr.io/github/gh-aw-firewall/api-proxy:0.28.73@sha256:a1860172a0d22b5f8190bde334794b5ed7dd93dd79583d09fbce8fe8c1751a56
      squid: ghcr.io/github/gh-aw-firewall/squid:0.28.73@sha256:fa0620bd3506ee69e450426a9f2ac8b13a81544604c244d2de2b0106eb03809f

# The audit itself runs in the job below, which has the audit script and a real
# checkout of every target. The agent only reads the rendered plan, so it needs
# no shell, no `gh`, and no repository access at all: that keeps a slow model
# from redoing deterministic work (and from failing at it).
tools:
  edit:
  # gh-aw enables a read-only GitHub MCP server by default. The plan already
  # carries every fact this agent publishes, so leave it off rather than pay
  # for its tool schemas on every turn.
  github: false

# Every write happens in a separate job through these handlers, using the PAT
# so issues land in the audited repository rather than in this one.
safe-outputs:
  github-token: ${{ secrets.ORCHESTRATOR_PAT }}
  create-issue:
    target-repo: "*"
    labels: [automated-health]
    max: 50
    expires: false
  update-issue:
    target: "*"
    target-repo: "*"
    body:
    max: 50
  # The detector runs on the Copilot engine and needs COPILOT_GITHUB_TOKEN,
  # which this repository does not configure; leaving it on would fail the job
  # before any safe output is applied. The agent job is read-only and every
  # write below happens in the isolated safe-outputs job instead.
  threat-detection: false

timeout-minutes: 45

network:
  allowed:
    - defaults
    - github

# The audit is deterministic: resolve the targets, run the shared sensor script
# per repository, then merge the rendered bodies into one plan. Only publishing
# is left to the agent.
jobs:
  prepare-targets:
    name: prepare targets
    runs-on: ubuntu-latest
    timeout-minutes: 10
    permissions:
      contents: read
    outputs:
      targets: ${{ steps.targets.outputs.targets }}
      count: ${{ steps.targets.outputs.count }}
    steps:
      - name: Resolve targets and ensure the health label
        id: targets
        env:
          GH_TOKEN: ${{ secrets.ORCHESTRATOR_PAT }}
          REQUESTED_REPOS: ${{ github.event.inputs.repos }}
          LIMIT: ${{ github.event.inputs.limit }}
        run: |
          set -euo pipefail
          targets=()
          if [[ -n ${REQUESTED_REPOS//[[:space:]]/} ]]; then
            IFS=',' read -ra requested <<<"$REQUESTED_REPOS"
            for entry in "${requested[@]}"; do
              entry=${entry//[[:space:]]/}
              [[ -n $entry ]] && targets+=("$entry")
            done
          else
            # --paginate --jq emits one repository per line, which stays valid
            # paginate output; this is the filter the pipeline uses.
            while IFS= read -r repo; do
              [[ -n $repo ]] && targets+=("$repo")
            done < <(gh api user/repos --paginate \
              --jq '.[] | select(.archived == false and .fork == false) | .full_name')
          fi

          if [[ $LIMIT =~ ^[0-9]+$ ]] && ((LIMIT > 0)) && ((${#targets[@]} > LIMIT)); then
            printf '::notice::Auditing the first %s repositories; skipped: %s\n' \
              "$LIMIT" "${targets[*]:LIMIT}"
            targets=("${targets[@]:0:LIMIT}")
          fi

          if ((${#targets[@]} == 0)); then
            echo "::warning::No repositories resolved for this run"
            echo 'targets=[]' >>"$GITHUB_OUTPUT"
            echo 'count=0' >>"$GITHUB_OUTPUT"
            exit 0
          fi

          # The label is not optional: the remediation pipeline finds health
          # issues by label, and issue creation fails when it does not exist.
          for repo in "${targets[@]}"; do
            if ! gh label create automated-health --repo "$repo" \
              --description "Tracked by automated health-check pipeline" \
              --color 0E8A16 --force >/dev/null 2>&1; then
              echo "::warning::Could not create the automated-health label on $repo"
            fi
          done

          list=$(printf '%s\n' "${targets[@]}" | jq -Rnc '[inputs]')
          {
            echo "targets=$list"
            echo "count=${#targets[@]}"
          } >>"$GITHUB_OUTPUT"

  # Run the same sensor script as the scheduled pipeline for every target, in
  # one job with a bounded pool. Sensors are read-only, so parallel clones and
  # audits are safe, and this costs no model turns however many repositories
  # are in scope. Nothing here decides anything: it renders one body per
  # repository and records whether that repository was actually audited.
  audit-targets:
    name: audit ${{ needs.prepare-targets.outputs.count }} repositories
    needs: prepare-targets
    if: needs.prepare-targets.outputs.count != '0'
    runs-on: ubuntu-latest
    timeout-minutes: 30
    # Reading this repository is all the workflow token needs; every GitHub read
    # of an audited repository goes through ORCHESTRATOR_PAT below.
    permissions:
      contents: read
    env:
      GH_TOKEN: ${{ secrets.ORCHESTRATOR_PAT }}
      TARGETS_JSON: ${{ needs.prepare-targets.outputs.targets }}
      # Each audit runs npm/pip plus a handful of API calls; four at a time
      # keeps a ten-repository run well inside the job timeout.
      AUDIT_PARALLELISM: "4"
    steps:
      - name: Checkout health-check tooling
        uses: actions/checkout@v7.0.1
        with:
          path: .orchestrator

      # The step reports success even when individual repositories failed, and
      # exits only on its own bugs being recorded in the plan: failing here
      # would skip the publish job and hide the repositories that did succeed.
      - name: Audit each repository
        id: audit
        run: |
          set -uo pipefail
          mkdir -p out/entries out/bodies out/records targets

          audit_one() {
            local repo=$1 safe issue rc=0 findings error entry
            safe=${repo//\//__}
            entry="out/entries/$safe.json"

            if ! gh repo clone "$repo" "targets/$safe" -- --depth 1 \
              >"out/clone-$safe.log" 2>&1; then
              error=$(tail -n 1 "out/clone-$safe.log")
              printf '::warning::Could not clone %s: %s\n' "$repo" "$error"
              jq -n --arg repo "$repo" --arg error "clone failed: $error" \
                '{repo: $repo, status: "failed", error: $error}' >"$entry"
              return 0
            fi

            # The remediation pipeline targets the first open labelled issue, so
            # resolve it here instead of leaving the choice to the model.
            issue=$(gh issue list --repo "$repo" --label automated-health \
              --state open --json number --jq '.[0].number // empty' 2>/dev/null) || issue=""

            REPO="$repo" TARGET_DIR="$PWD/targets/$safe" \
              AUDIT_RECORD_DIR="$PWD/out/records" \
              BODY_FILE="$PWD/out/bodies/$safe.md" DRY_RUN=1 \
              bash .orchestrator/.github/scripts/audit-repo.sh >"out/audit-$safe.log" 2>&1 || rc=$?
            sed "s|^|[$repo] |" "out/audit-$safe.log"

            if ((rc != 0)); then
              error=$(grep -m1 'error:' "out/audit-$safe.log" || tail -n 1 "out/audit-$safe.log")
              printf '::warning::Audit of %s failed: %s\n' "$repo" "${error:-exit $rc}"
              jq -n --arg repo "$repo" --arg error "${error:-audit script exited $rc}" \
                '{repo: $repo, status: "failed", error: $error}' >"$entry"
              return 0
            fi

            findings=$(jq -r '.findings // 0' "out/records/$safe.json" 2>/dev/null) || findings=""
            if ! [[ $findings =~ ^[0-9]+$ ]]; then
              printf '::warning::Audit record for %s is missing or unreadable\n' "$repo"
              jq -n --arg repo "$repo" \
                '{repo: $repo, status: "failed", error: "audit record missing or unreadable"}' >"$entry"
              return 0
            fi

            jq -n --arg repo "$repo" --argjson findings "$findings" \
              --arg body "bodies/$safe.md" --arg issue "${issue:-}" '
              {repo: $repo, status: "audited", findings: $findings, body: $body}
              + (if $issue == "" then {issue: null} else {issue: ($issue | tonumber)} end)
            ' >"$entry"
          }

          running=0
          while IFS= read -r repo; do
            [[ -n $repo ]] || continue
            audit_one "$repo" &
            running=$((running + 1))
            if ((running >= AUDIT_PARALLELISM)); then
              wait -n
              running=$((running - 1))
            fi
          done < <(jq -r '.[]' <<<"$TARGETS_JSON")
          wait

          exit 0

      # A partially written plan is still useful, and a target with no entry is
      # reported as unaudited rather than silently dropped.
      - name: Build the publish plan
        if: always()
        run: |
          set -euo pipefail
          mkdir -p health-audit
          shopt -s nullglob
          targets_json=${TARGETS_JSON:-[]}

          while IFS= read -r repo; do
            [[ -n $repo ]] || continue
            safe=${repo//\//__}
            entry="out/entries/$safe.json"
            if [[ ! -s $entry ]]; then
              jq -n --arg repo "$repo" \
                '{repo: $repo, status: "failed", error: "audit did not run to completion"}' >"$entry"
            fi
          done < <(jq -r '.[]' <<<"$targets_json")

          entries=(out/entries/*.json)
          if ((${#entries[@]} == 0)); then
            echo '[]' >/tmp/targets.json
          else
            jq -s '.' "${entries[@]}" >/tmp/targets.json
          fi
          jq --arg title "🛡️ [Health Audit] Security Vulnerabilities & Dependency Maintenance" \
            '{title: $title, targets: (sort_by(.repo))}' /tmp/targets.json >health-audit/plan.json

          [[ -d out/bodies ]] && cp -a out/bodies health-audit/bodies
          [[ -d out/records ]] && cp -a out/records health-audit/records
          if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
            jq -r '.targets[] | "- `\(.repo)` — \(.status)\(if .findings then " (\(.findings) finding(s))" else "" end)"' \
              health-audit/plan.json >>"$GITHUB_STEP_SUMMARY"
          fi

      - name: Write the inventory summary
        if: always()
        run: |
          set -uo pipefail
          [[ -n ${GITHUB_STEP_SUMMARY:-} ]] || exit 0
          bash .orchestrator/.github/scripts/render-report.sh health-audit/records \
            >>"$GITHUB_STEP_SUMMARY" || true

      - name: Store the plan for the agent
        if: always()
        uses: actions/upload-artifact@v7.0.2
        with:
          name: health-audit
          path: health-audit
          if-no-files-found: error
          retention-days: 1

# The plan is written by audit-targets into the agent workspace before the
# engine starts.
pre-agent-steps:
  - name: Restore the audit plan
    uses: actions/download-artifact@v8.0.2
    with:
      name: health-audit
      path: ${{ github.workspace }}/health-audit
---

# Manual repository health audit

`health-audit/plan.json` was produced before you started, by the same
deterministic sensors the scheduled pipeline runs
(`.github/scripts/audit-repo.sh`). The audit is finished. Your job is to publish
it: one issue per repository that has findings, nothing else.

You have no shell and no `gh` access in this run, by design. Do not try to
re-audit, clone, or fetch anything. Do not edit the plan or the body files. A
finding that seems to be missing is not evidence that it exists.

## The plan

`health-audit/plan.json`:

```json
{
  "title": "🛡️ [Health Audit] Security Vulnerabilities & Dependency Maintenance",
  "targets": [
    {"repo": "owner/name", "status": "audited", "findings": 3, "issue": 138, "body": "bodies/owner__name.md"},
    {"repo": "owner/other", "status": "audited", "findings": 0, "issue": null, "body": "bodies/owner__other.md"},
    {"repo": "owner/broken", "status": "failed", "error": "GitHub authentication failed"}
  ]
}
```

- `status: "audited"` — the sensors ran; `findings` counts actionable items.
- `status: "failed"` — the sensors could not run for that repository. It is not
  clean and not healthy; it is unaudited. Never publish for it.
- `issue` — the number of the repository's existing open `automated-health`
  issue, or `null` when it has none.
- `body` — path, relative to `health-audit/`, of the exact issue body to publish.

## What to publish

Walk `targets` in order and act on each entry:

1. `status` is not `audited`: skip it. It is reported by the run summary.
2. `findings` is `0`: skip it. A repository with no findings gets no issue, and
   an existing issue is left alone rather than blanked.
3. `issue` is `null`: call `create_issue`.
4. Otherwise: call `update_issue` for that issue number.

Publish the body file verbatim: read `health-audit/<body>`, and pass its exact
contents as the `body` argument. Kinds of edit that are forbidden include
rewriting counts, adding a finding the sensors did not report, dropping a
sensor-warnings section, and "fixing" Markdown. The remediation pipeline parses
this body, so it must be the sensors' text.

## Every call must name its repository

The workflow allows writes to any repository (`target-repo: "*"`), so the
repository is never implied by context and there is no default:

- `create_issue` requires `repo` (for example `"repo": "owner/name"`), plus
  `title` and `body`.
- `update_issue` requires `repo`, `item_number` (the plan's `issue`), and
  `body`.

`"repo": "*"` and an omitted `repo` both fail the write. Use the `repo` value
from the plan entry, exactly as written.

## Finishing

- The run summary, including every skipped and failed target, is written by the
  audit job. Do not write files or a summary of your own.
- If `plan.json` is missing, unreadable, or has no `targets`, the audit did not
  run: call `report_incomplete` with the reason. Do not call `noop`.
- If every entry failed, nothing was audited: call `report_incomplete`, listing
  the repositories and their errors. Never call `noop` for an unaudited run.
- Call `noop` only when every entry was audited and none had findings. Say how
  many repositories that covered.
- If any `create_issue`/`update_issue` call fails, say which repository in your
  final message; do not retry the same call more than once.
