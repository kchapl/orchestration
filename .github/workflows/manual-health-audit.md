---
emoji: "🩺"
description: "On-demand audit of every owned repository that raises or refreshes its automated-health issue."
intent: "Keep repository security, dependency, and workflow findings visible on demand, using an agent instead of the scheduled sensor pipeline."
labels: ["automation", "security", "maintenance"]

on:
  workflow_dispatch:
    inputs:
      repos:
        description: "Comma-separated owner/name repositories to audit (blank = discover every non-archived, non-fork repository)"
        required: false
        type: string
      limit:
        description: "Maximum number of repositories to audit in this run (0 = no cap). Each repository costs model turns against the Gemini free tier."
        required: false
        type: string
        default: "0"

# One agent conversation spends one shared LLM quota; queue runs rather than
# letting two manual runs audit the same repositories at the same time.
concurrency:
  group: manual-health-audit
  cancel-in-progress: false
  # Each dispatch keeps its own conclusion slot while the group above still
  # serializes the audit itself.
  job-discriminator: ${{ github.run_id }}

permissions:
  contents: read
  # Read scopes for the GitHub toolsets; the tools themselves authenticate with
  # ORCHESTRATOR_PAT so they can read the audited repositories too.
  issues: read
  security-events: read
  vulnerability-alerts: read

engine:
  id: agy
  model: gemini-3.5-flash-lite
  # Newest native release this gh-aw compiler verifies a checksum for.
  version: "1.3.3"

# The audit reads other repositories, so the agent needs the orchestrator PAT
# rather than the workflow's repository-scoped token.
tools:
  edit:
  # npm audit and pip-audit run in the agent workspace, so shell access cannot
  # be narrowed; Agy rejects per-command bash restrictions anyway.
  bash: true
  github:
    toolsets: [repos, issues, code_security, dependabot]
    github-token: ${{ secrets.ORCHESTRATOR_PAT }}

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
  # The Agy engine has no threat-detection pass (its documented gate disables
  # the Copilot detector), and the agent job holds no write permission: every
  # write below happens in the isolated safe-outputs job.
  threat-detection: false

timeout-minutes: 45

network:
  allowed:
    - defaults
    - github
    - node
    - python

# Resolve the target list and create the tracking label before the agent starts.
# This is deterministic setup, so it runs in a custom job rather than in the
# read-only agent job. The label is not optional: the remediation pipeline finds
# health issues by label, and issue creation fails when it does not exist yet.
jobs:
  prepare-targets:
    name: prepare targets
    runs-on: ubuntu-latest
    timeout-minutes: 10
    permissions:
      contents: read
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

          if ((${#targets[@]} == 0)); then
            : >health-audit-targets.txt
            echo "::warning::No repositories resolved for this run"
            exit 0
          fi

          if [[ $LIMIT =~ ^[0-9]+$ ]] && ((LIMIT > 0)) && ((${#targets[@]} > LIMIT)); then
            printf '::notice::Auditing the first %s repositories; skipped: %s\n' \
              "$LIMIT" "${targets[*]:LIMIT}"
            targets=("${targets[@]:0:LIMIT}")
          fi

          printf '%s\n' "${targets[@]}" >health-audit-targets.txt
          for repo in "${targets[@]}"; do
            if ! gh label create automated-health --repo "$repo" \
              --description "Tracked by automated health-check pipeline" \
              --color 0E8A16 --force >/dev/null 2>&1; then
              echo "::warning::Could not create the automated-health label on $repo"
            fi
          done

      - name: Store the target list for the agent
        uses: actions/upload-artifact@v7.0.2
        with:
          name: health-audit-targets
          path: health-audit-targets.txt
          if-no-files-found: error
          retention-days: 1

# The agent workspace is restored from the checkout, so the target list is
# downloaded there before the engine starts.
pre-agent-steps:
  - name: Restore the resolved target list
    uses: actions/download-artifact@v8.0.2
    with:
      name: health-audit-targets
      path: ${{ github.workspace }}
---

# Manual repository health audit

You are the on-demand, agentic counterpart of
`.github/workflows/daily-health-check.yml`. That workflow discovers the
account's repositories, runs deterministic audit sensors, and opens one
`automated-health` issue per repository that has actionable findings. You do
the same audit yourself, with GitHub tools and shell commands, and publish the
result through safe outputs.

This run was dispatched manually, so there is no schedule and no previous run
to build on: resolve the target list and audit it from scratch every time.

## Targets

Requested repositories from the dispatcher: `${{ github.event.inputs.repos }}`
(the value may be empty). The workflow resolved the target list before you
started and wrote one `owner/name` per line to `health-audit-targets.txt` in
the workspace, and created the `automated-health` label on each target.

1. Read `health-audit-targets.txt` and audit exactly those repositories. If the
   file is missing or empty, fall back to discovery: every repository owned by
   `${{ github.repository_owner }}` that is neither archived nor a fork, the
   same filter the pipeline uses.
2. The `limit` input (`${{ github.event.inputs.limit }}`) has already been
   applied to that file. Spend the same budget the list implies; do not add
   repositories beyond it.
3. Never invent a repository. If discovery or a per-repository read fails with
   an authentication or permission error, stop and report a hard failure for
   the affected scope: a broken token must never produce a clean audit. A
   private repository that the workflow's visibility protections make
   unreadable is reported as a skipped target, not silently treated as clean.
4. The audit is read-only. Do not modify files in a checked-out repository,
   push commits, or change issues other than the health issue described below.
   Scratch files in a temporary directory outside the checkout are expected.

## Per-repository checks

Run these checks for each target. Treat a feature that is simply not enabled for
a repository - code scanning with no analyses, Dependabot alerts switched off -
as a note, not a warning; it says nothing about the repository's health. Report
any other failure as a sensor warning and continue with the remaining checks.

1. **Dependabot alerts** - open alerts, with severity, package, summary, and
   alert link. If the token cannot read alerts, record the warning that the
   token needs `security_events` (classic PAT) or the matching read permission
   on a fine-grained PAT.
2. **Code scanning alerts** - open alerts, with severity, rule id, description,
   and file path. Missing analyses are a note ("not enabled for this
   repository, or has no analyses yet"), not a warning.
3. **npm advisories** - only when the repository has `package-lock.json` or
   `npm-shrinkwrap.json`. Fetch the manifest and lockfile into a temporary
   directory outside the checkout, then run `npm audit --json` there. Report every finding
   whose severity is not `info` with its severity, package, and advisory title.
   A lockfile that cannot be parsed is a sensor warning.
4. **Python advisories** - only when the repository has `requirements*.txt`.
   Fetch each file and run `pip-audit -r <file> --format=json`. If `pip-audit`
   is not on `PATH`, install it with `python3 -m pip install --user pip-audit`;
   if that fails, report a sensor warning instead of guessing. Report each
   vulnerable package with its fix versions (or "no fix available") and the
   advisory id.
5. **GitHub Actions pinning** - read `.github/workflows/*.yml` (and `.yaml`)
   and collect every external `uses:` reference. A reference is pinned when it
   is a 40-character commit SHA, or when it appears in that workflow's entry in
   `.github/workflows/actions.lock` (the workflow is onboarded and the locked
   commit is what Actions executes). Local paths, `docker://` images, and
   expression-based refs are not versioned actions and are ignored. Report each
   unpinned reference with its file, line number, and the reason (`not in
   actions.lock for this workflow`, `no ref specified`, or `ref '<ref>' is not
   a commit SHA`).
6. **GitHub Actions versions** - for each distinct `uses:` action, look up its
   latest published release once per run and cache the answer. A floating major
   tag such as `@v7` tracks its own major line and is reported only once the
   action has moved to a newer major; a full version such as `@v4.4.0` must be
   the newest release in its major. Resolve commit pins back to the ref they
   were locked from through `actions.lock`; skip a reference whose version
   cannot be resolved. Report the version to move to, never an older version,
   and note when the current ref is a commit pin.
7. **Primary language** - read it from repository metadata. The supported set
   is `Python Shell TypeScript Scala JavaScript Unspecified`. A language outside
   that set is a note that remediation can still edit files but native test
   suites may need a custom toolchain.
8. **Archival candidate** - inspect recent commit history. The repository is a
   candidate when no commit in the last 100 has a human author (a non-`User`
   author type, or a login containing `bot`, does not count) in the last year.
   Report the date of the last human commit, or that there was none.

Bound the work: stop a repository's remaining checks after repeated rate-limit
or network failures, and do not retry the same failing call more than twice.

## Issue rules

Publish at most one health issue per repository, and only when that repository
has at least one finding from the checks above. Notes alone (an unsupported
language, a repository that is not enrolled in code scanning) and sensor
warnings alone do not justify an issue.

- Title: `🛡️ [Health Audit] Security Vulnerabilities & Dependency Maintenance`
- Label: `automated-health`
- Before creating, list the repository's open issues and look for an existing
  issue with the `automated-health` label. Update that issue's body instead of
  creating a duplicate; the pipeline treats the first open issue as the
  remediation target.
- Target the audited repository, never this repository, when creating or
  updating.
- Omit the issue entirely when the repository has no findings.

Use this body, with real counts and findings, in this order. For every section,
use its bullet list when the count is above zero and its italic fallback line
when the count is zero:

```markdown
### 🛡️ Automated Repository Health Audit Findings

Repository: **<owner/name>**

> **⚠️ Unsupported primary language:** `<language>` is outside the supported set (<supported set>).
> **📦 Archival candidate:** last human commit was <YYYY-MM-DD> (over a year ago). Consider `gh repo archive <owner/name>`.

#### Dependabot alerts (<count>)

- **<SEVERITY>** <package> — <summary> ([alert #<number>](<url>))
_No open Dependabot alerts._

#### Code scanning alerts (<count>)

- **<severity>** <rule id> — <description> (<path>)
_No open code scanning alerts._

#### Dependency audit findings (<count>)

- **<SEVERITY>** <package> — <advisory>
_No vulnerable dependencies detected by local audits._

#### GitHub Actions pinning (<count>)

- `<file>:<line>` — `<uses ref>` (<reason>)
Every `uses:` ref is a commit SHA or is covered by `actions.lock`.

#### GitHub Actions versions (<count>)

- `<uses ref>` is <N major versions behind|an older <major>.x release>; latest is `<tag>` (`<file>:<line>`)
Every `uses:` ref is on the latest release of its action.

#### Sensor warnings

> These sensors could not complete. Their sections above may be incomplete.

- **<sensor>**: sensor failed — <reason>

---
<sub>Generated by the manual agentic health audit. Phase 2 may open a draft PR against this issue; close it to opt out.</sub>
```

Keep the section headings even when a section is empty, using the italic
fallback line shown above. Include the language and archival notes only when
they apply, and the sensor warnings section only when a check failed. Do not
invent findings, links, counts, or severity; if a value is unknown, say so.

## Finish

Write a short step summary: the repositories audited, the repositories with
findings, the issues created or updated, and the repositories skipped by
`limit` or by an access failure. Use the `noop` output only when you audited
the targets and no repository needed an issue, so the run records a clean
result instead of an empty output.
