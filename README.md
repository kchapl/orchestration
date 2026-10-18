# orchestration

Cross-repo maintenance automation.

## Two-phase polyglot health check

`.github/workflows/daily-health-check.yml` discovers non-archived, non-fork
repositories, audits them in parallel, and then remediates only repositories
with an open `automated-health` issue:

1. **`audit-and-raise-issues`** — runs `.github/scripts/audit-repo.sh` against each
   target checkout and creates or updates an issue when it finds actionable
   findings.
2. **`find-remediation`** — checks for open health issues with bounded parallel
   API calls and builds a remediation matrix.
3. **`resolve-issues`** — runs one job per affected repository with the
   OpenHands 1.x headless CLI and opens a draft PR. The CLI is installed in that
   job with `uv`, and the agent runs directly in the repository checkout.

At most four remediation jobs run concurrently. Repositories without open
issues never get a job and do not incur checkout or tool setup. Because each
repository has its own job, a slow or failing remediation does not delay the
others.

Phase 1 runs independent sensors in two groups, with at most four concurrent
sensors per repository. Output is collected in a stable order and failures
remain isolated as warnings.

Phase 2 installs only the OpenHands CLI (pinned by `OPENHANDS_VERSION` in
`.github/scripts/remediate-issue.sh`, currently 1.16.0). The 1.x headless CLI
runs the agent in the checkout itself, so it uses the runner's existing Node,
Python, Java, and Shellcheck rather than a separate runtime image. The CLI
exits successfully even when a conversation errors, so the script inspects the
streamed events for `ConversationErrorEvent` and fails that repository
instead of opening an empty PR. After workflow edits it runs `gh actions-lock`
to create or refresh `.github/workflows/actions.lock`, so action refs stay as
tags rather than commit SHAs. The agent defaults to `deepseek/deepseek-flash`
(DeepSeek V4.1 Flash); override `LLM_MODEL` to use another LiteLLM model.
Repository clones are shallow; commits created by OpenHands are pushed to a new
issue branch, so the target's full history is not required for remediation.

### Phase 1 sensors

| Sensor | Source |
| --- | --- |
| Dependabot alerts | `repos/{repo}/dependabot/alerts` |
| Code scanning alerts | `repos/{repo}/code-scanning/alerts` |
| npm advisories | `npm audit --json` (requires a lockfile) |
| Python advisories | `pip-audit -r requirements*.txt` |
| GitHub Actions pinning | `uses:` refs that are neither a 40-char commit SHA nor covered by `.github/workflows/actions.lock` |
| Primary language | `repos/{repo}` metadata |
| Archival candidate | no human-authored commit in over a year |

Repos that use the official workflow lockfile are not nagged: a workflow listed
in `.github/workflows/actions.lock` counts as pinned when every `uses:` ref it
contains has a pin entry, because Actions executes the locked commit. A ref
missing from the lockfile, or a workflow that has not been onboarded at all, is
still reported.

Every sensor runs in isolation: a sensor that fails (missing tool, API error) is
reported as a warning and in the issue body, and the other sensors still run.
A feature that is simply not enabled for the repo — CodeQL with no analyses
(`HTTP 404`), Dependabot alerts switched off — is a note in its section, not a
warning, because it says nothing about the repo's health. Findings, not sensor
health, decide whether an issue is raised. An authentication failure is the one
hard error, so a broken token can never produce a green "all clean" run.

### Run summary

Every audit job writes a JSON inventory record, and the `report` job aggregates
them into the workflow run summary:

- repositories where code scanning is not enabled
- candidates for archiving, with the date of the last human commit
- repositories whose primary language is outside the supported set

The report is advisory: if a run produced no records, the summary says so
rather than failing.

### Running the audit locally

`gh` must be authenticated (`GH_TOKEN` or `gh auth login`); `jq` is required.

```sh
# Audit the current checkout and print the issue body without writing anything
REPO=owner/name DRY_RUN=1 ./.github/scripts/audit-repo.sh

# Audit another checkout, creating/updating the issue if findings exist
REPO=owner/name TARGET_DIR=/path/to/checkout ./.github/scripts/audit-repo.sh

# Write inventory records, then render the run summary from them
REPO=owner/name AUDIT_RECORD_DIR=records ./.github/scripts/audit-repo.sh
./.github/scripts/render-report.sh records >> "$GITHUB_STEP_SUMMARY"
```

### Required secrets

| Secret | Purpose |
| --- | --- |
| `ORCHESTRATOR_PAT` | repo discovery, issue writes, checkouts, PR pushes |
| `DEEPSEEK_API_KEY` | OpenHands model access in phase 2 (DeepSeek V4.1 Flash) |

`ORCHESTRATOR_PAT` also needs read access to security alerts, otherwise phase 1
reports "the token cannot read …". On a classic PAT that is the
`security_events` scope; on a fine-grained PAT grant *Dependabot alerts: read*
and *Code scanning alerts: read*.
