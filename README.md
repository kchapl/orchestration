# orchestration

Cross-repo maintenance automation.

## Two-phase polyglot health check

`.github/workflows/daily-health-check.yml` runs in two phases, both fanned out
over every non-archived, non-fork repo the token can see:

1. **`audit-and-raise-issues`** — runs `.github/scripts/audit-repo.sh` against the
   target checkout and creates or updates one open `automated-health` issue per
   repo that has actionable findings.
2. **`resolve-issues`** — hands that issue to OpenHands and opens a draft PR.
   It skips a repo that has no open health issue.

### Phase 1 sensors

| Sensor | Source |
| --- | --- |
| Dependabot alerts | `repos/{repo}/dependabot/alerts` |
| Code scanning alerts | `repos/{repo}/code-scanning/alerts` |
| npm advisories | `npm audit --json` (requires a lockfile) |
| Python advisories | `pip-audit -r requirements*.txt` |
| GitHub Actions pinning | `uses:` refs that are not 40-char commit SHAs |
| Primary language | `repos/{repo}` metadata |
| Archival candidate | no human-authored commit in over a year |

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
| `GEMINI_API_KEY` | OpenHands model access in phase 2 |

`ORCHESTRATOR_PAT` also needs read access to security alerts, otherwise phase 1
reports "the token cannot read …". On a classic PAT that is the
`security_events` scope; on a fine-grained PAT grant *Dependabot alerts: read*
and *Code scanning alerts: read*.
