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
tags rather than commit SHAs. Version findings from phase 1 are applied in the
same pass: a ref the issue reports as behind is moved to the release named
there, or to that release's major tag when the ref floats on a major, and never
to an older version. Opening the draft PR does not finish the job:
the script then reads the pull request's check rollup and waits for every
check to settle, failing its own run and naming each failed check with its log
link when any of them fails. `PR_CHECK_TIMEOUT` (default 900 s) bounds the
wait, `PR_CHECK_INTERVAL` (default 15 s) sets the poll period, and
`PR_CHECK_START_GRACE` (default 120 s) covers the delay before the first check
is registered. A repository whose pull requests report no checks at all is
noted and allowed through, since there is nothing to verify. The agent is
also told to read `.github/workflows/*.yml` and run the lint, formatter, type
checker, and tests those jobs run, so a green PR is the expected outcome
rather than a lucky one. The remediation workflow uses Google's
`gemini/gemini-3.5-flash-lite` through LiteLLM — a stable Flash-Lite model
that Google names for new free-tier projects and that targets high-throughput
agent workloads. It writes a private, temporary
OpenHands agent configuration with prompt caching disabled for both the agent
and its condenser, avoiding explicit cached-content creation that exceeds the
Gemini free tier's zero cache-storage quota. The file is removed after the run.
The workflow retries transient LLM errors with up to eight attempts,
exponential backoff, and a 60-second cap; retries cannot fix quota errors on
their own. **The free-tier daily request quota is the binding constraint on
phase 2.** One remediation conversation needs dozens of model calls, so the
model has to have a daily request allowance that covers a full run; the free
tier of `gemini-3.8-flash` allows only 20 requests per day per project per
model and dies mid-conversation with `429 RESOURCE_EXHAUSTED`. Flash-Lite
models carry a far larger daily allowance on the same free tier, which is why
phase 2 runs on `gemini-3.5-flash-lite`. Google does not publish per-model
free-tier RPD figures — the error names the exhausted limit, and AI Studio
shows the limits in force for the project that owns the key. The quota resets
at midnight Pacific. When a run does hit the cap, `remediate-issue.sh` reports
the exhausted limit and the reset hint instead of a generic failure, and the
workflow serializes runs with `concurrency` so overlapping manual runs cannot
spend the same budget twice. To move the ceiling again, set `LLM_MODEL` to
another model with a free tier row. Gemini 3.5 Flash-Lite has a 1,048,576-token
input limit and a 65,536-token output limit. The
Gemini API free tier currently includes free input and output tokens for
eligible models, but request and token rate limits are project-specific; check
AI Studio for the limits active on your project. Google may use free-tier
content to improve its products. The temporary agent configuration prevents
OpenHands from adding explicit cache markers; it does not change Google's
separate implicit caching behavior or guarantee against other 429 quota/rate-
limit errors. Repository clones are shallow; commits
created by OpenHands are pushed to a new issue branch, so the target's full
history is not required for remediation. To quickly verify the temporary agent
configuration without calling Gemini, run the manual-only
`Verify OpenHands Gemini Config` workflow; it installs the pinned CLI and checks
that caching stays disabled for the agent and condenser.

### Phase 1 sensors

| Sensor | Source |
| --- | --- |
| Dependabot alerts | `repos/{repo}/dependabot/alerts` |
| Code scanning alerts | `repos/{repo}/code-scanning/alerts` |
| npm advisories | `npm audit --json` (requires a lockfile) |
| Python advisories | `pip-audit -r requirements*.txt` |
| GitHub Actions pinning | `uses:` refs that are neither a 40-char commit SHA nor covered by `.github/workflows/actions.lock` |
| GitHub Actions versions | `repos/{action}/releases/latest` for each `uses:` action, falling back to its tags |
| Primary language | `repos/{repo}` metadata |
| Archival candidate | no human-authored commit in over a year |

Repos that use the official workflow lockfile are not nagged: a workflow listed
in `.github/workflows/actions.lock` counts as pinned when every `uses:` ref it
contains has a pin entry, because Actions executes the locked commit. A ref
missing from the lockfile, or a workflow that has not been onboarded at all, is
still reported.

Action versions are checked separately from pinning. Each `uses:` ref is
compared with its action's latest published release, so the issue names the
version to move to instead of only saying the workflow is stale. A floating
major tag (`@v7`) tracks its own major line and is reported only once the action
moves to a newer major; a full version such as `@v4.4.0` must be the newest
release in its major. Commit pins are resolved back to the ref they were locked
from through `actions.lock`, so SHA-pinned workflows are checked too; a ref with
no resolvable version (a branch, a private action, or a repository that publishes
no version tags) is skipped rather than guessed at. Each action is queried once
per run and the result is cached, so a repository with a dozen workflows costs
one API call per distinct action.

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

### Manual agentic audit (experimental)

`.github/workflows/manual-health-audit.md` is the on-demand agentic counterpart
of phase 1. It is a GitHub Agentic Workflow: `gh aw compile` renders it to
`.github/workflows/manual-health-audit.lock.yml`, and the lock file is what
Actions runs. Edit the Markdown, never the lock file.

- **Trigger:** `workflow_dispatch` only. Inputs are `repos` (comma-separated
  `owner/name`, blank discovers every non-archived, non-fork repository with
  the same filter the pipeline uses) and `limit` (maximum repositories per run,
  `0` = no cap).
- **Engine:** `gemini` (Google Gemini CLI, pinned to `0.64.0`) on
  `gemini-3.5-flash-lite` — the same Flash-Lite model phase 2 uses. Agy was the
  first choice, but its native CLI exposes only Gemini 3.8, 3.7, and 3.6 Flash
  plus 3.1 Pro, with no Flash-Lite slug in any release gh-aw can install, and
  the run fails at model selection before inference. The Gemini engine keeps
  the model; it is deprecated upstream in favour of Agy but still supported.
  It authenticates with `GEMINI_API_KEY`.
- **Sandbox:** the AWF firewall is pinned to `v0.28.73` because the compiler's
  bundled `v0.28.57` stages the Gemini CLI system settings under
  `$HOME/.awf`, which Gemini CLI `0.64.0` refuses to load because the directory
  is not root-owned, so the agent exits `41` with `Invalid auth method
  selected.` before inference. `v0.28.73` stages the same file under the
  root-owned `/etc/awf/gemini-cli/`. The three container roles are digest-pinned
  in frontmatter because the compiler's digest table only covers its bundled
  version.
- **Behavior:** a deterministic `prepare-targets` job resolves the repository
  list, publishes it as the `health-audit-targets` artifact, and creates the
  `automated-health` label where it is missing, because the remediation
  pipeline finds issues by label and issue creation fails without it. The agent
  then audits each repository with `gh` (Dependabot and code scanning alerts,
  repository metadata, commit history, releases, workflow files) and shell
  commands for the local dependency audits (`npm audit`, `pip-audit`, npm and
  PyPI network access), and raises or refreshes one health issue per repository
  with findings. Issue bodies keep the pipeline's section order so phase 2 can
  read them. `tools.github.mode: gh-proxy` makes `gh` pre-authenticated without
  putting the token in the sandbox: a host CLI proxy started by the workflow
  holds `ORCHESTRATOR_PAT`, and the agent's `gh` traffic is relayed to it under
  the same public-repository guard policy as the rest of the pipeline. The
  agent container excludes `GH_TOKEN`, and `api.github.com` is only reachable
  through that proxy.
- **Writes:** the agent job is read-only. Issues are created or updated by the
  isolated safe-outputs job with `ORCHESTRATOR_PAT`, targeted at the audited
  repository.
- **Security:** threat detection is disabled because the detector only runs on
  the Copilot engine and this repository configures no Copilot credentials; the
  agent job holds no write permission and every write is staged through safe
  outputs. The audit never modifies source files.
- **Cost:** one agent conversation covers the whole run, so `limit` bounds how
  many repositories one dispatch handles; each repository costs model turns
  against the Gemini free-tier request quota. The agentic step is capped at 45
  minutes and the concurrency group queues manual runs.
- **Scope:** this workflow raises issues; it does not open pull requests. Phase
  2 remediation stays in `daily-health-check.yml`, which consumes the same
  issues.

Regenerate the lock file after editing the Markdown:

```sh
gh aw compile manual-health-audit
```

### Required secrets

| Secret | Purpose |
| --- | --- |
| `ORCHESTRATOR_PAT` | repo discovery, cross-repository reads, issue writes, checkouts, PR pushes |
| `GEMINI_API_KEY` | Google AI Studio API key for OpenHands model access in phase 2 and for the Gemini engine in the manual audit |

Create or manage a Gemini API key in [Google AI Studio](https://aistudio.google.com/api-keys),
then add it to this repository's Actions secrets as `GEMINI_API_KEY`.

`ORCHESTRATOR_PAT` also needs read access to security alerts, otherwise phase 1
reports "the token cannot read …". On a classic PAT that is the
`security_events` scope; on a fine-grained PAT grant *Dependabot alerts: read*
and *Code scanning alerts: read*.
