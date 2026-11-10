---
name: Scala LTS Upgrade
description: Raise one verified Scala LTS upgrade pull request per eligible kchapl repository and track every outcome in a single tracker issue.
intent: Keep kchapl's Scala projects on the latest Scala LTS release by raising at most one verified upgrade pull request per repository, leaving current repositories and existing upgrade pull requests untouched.
emoji: 🪜
on:
  workflow_dispatch:
    inputs:
      repos:
        description: Comma-separated repository names to process (empty means every owned Scala repository)
        type: string
        required: false
      max_repos:
        description: Maximum number of eligible repositories to process in this run (1-10; empty uses the full 10 per-run pull request quota)
        type: string
        required: false
        default: "1"
      dry_run:
        description: Preview the intended upgrades and tracker update without writing anything
        type: boolean
        required: false
        default: true
permissions:
  contents: none
  issues: read
  pull-requests: read
concurrency:
  group: scala-lts-upgrade
  queue: single
  job-discriminator: ${{ github.run_id }}
checkout: false
# `checkout: false` drops the agent job's clone, but the generated safe_outputs
# job still configures git credentials before it can apply a
# create-pull-request output, and that script runs `git remote set-url origin`.
# Give that job a checkout of this repository so the credentials step has an
# origin remote to update instead of failing in a workspace with no `.git`.
jobs:
  safe_outputs:
    pre-steps:
      - name: Check out the workflow repository
        uses: actions/checkout@v7.0.1
        with:
          persist-credentials: false
          token: ${{ secrets.SCALA_LTS_PAT }}
engine: agy
timeout-minutes: 180
network:
  allowed: [defaults, github, java, scala, linux-distros]
tools:
  github:
    mode: gh-proxy
    github-token: ${{ secrets.SCALA_LTS_PAT }}
    toolsets: [repos, issues, pull_requests]
steps:
  - name: Resolve latest Scala LTS and build the repository plan
    # Custom steps do not receive the dispatch inputs automatically, and the plan
    # reads these two to honour `repos` and `max_repos` instead of scanning every
    # repository with the full ten-per-run quota.
    env:
      GH_AW_INPUTS_REPOS: ${{ inputs.repos }}
      GH_AW_INPUTS_MAX_REPOS: ${{ inputs.max_repos }}
    run: |
      set -euo pipefail
      mkdir -p /tmp/gh-aw/data
      python3 - <<'PY'
      import json, os, re, urllib.request

      DATA = "/tmp/gh-aw/data"
      UA = {"User-Agent": "gh-aw-scala-lts-upgrade"}

      def get(url):
          with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=60) as r:
              return r.read().decode("utf-8", "replace")

      page = get("https://www.scala-lang.org/download/")
      lines = [tuple(map(int, m)) for m in re.findall(r"(\d+)\.(\d+)\.x LTS", page)]
      if not lines:
          raise SystemExit("could not determine the current Scala LTS line")
      lts_line = "%d.%d" % max(lines)

      meta = get("https://repo1.maven.org/maven2/org/scala-lang/scala3-library_3/maven-metadata.xml")
      patches = [tuple(map(int, v.split("."))) for v in re.findall(r"<version>([0-9][^<]*)</version>", meta)
                 if re.fullmatch(re.escape(lts_line) + r"\.\d+", v)]
      if not patches:
          raise SystemExit("no published patch release for Scala LTS line " + lts_line)
      lts_version = "%d.%d.%d" % max(patches)
      json.dump({"lts_line": lts_line, "lts_version": lts_version}, open(f"{DATA}/lts.json", "w"), indent=2)

      repos = [r for r in json.loads(get("https://api.github.com/users/kchapl/repos?per_page=100&type=owner"))
               if not r["archived"] and not r["fork"] and r["owner"]["login"] == "kchapl"]
      wanted = [n.strip() for n in (os.environ.get("GH_AW_INPUTS_REPOS") or "").split(",") if n.strip()]
      if wanted:
          missing = sorted(set(wanted) - {r["name"] for r in repos})
          if missing:
              raise SystemExit("requested repositories not found or not owned: " + ", ".join(missing))
          repos = [r for r in repos if r["name"] in wanted]

      def parts(version):
          m = re.match(r"(\d+)\.(\d+)(?:\.(\d+))?", version)
          return tuple(int(x or 0) for x in m.groups()) if m else None

      def classify(current, lts):
          if not current:
              return "no_scala_version"
          c, l = parts(current), parts(lts)
          if c is None or l is None:
              return "unparsed_version"
          if c == l:
              return "already_current"
          if c[0] < l[0]:
              return "major_upgrade"
          if c[0] > l[0] or c[:2] > l[:2]:
              return "ahead_of_lts"
          return "upgrade"

      plan = []
      for r in sorted(repos, key=lambda x: x["name"]):
          name, branch = r["name"], r["default_branch"]
          try:
              build = get(f"https://raw.githubusercontent.com/kchapl/{name}/{branch}/build.sbt")
          except Exception:
              continue
          m = re.search(r'scalaVersion\s*:?=\s*"([^"]+)"', build)
          flags = sorted(set(re.findall(r'"(-Werror|-Xfatal-warnings|-deprecation|-unchecked|-Wunused[^"]*)"', build)))
          current = m.group(1) if m else None
          kind = classify(current, lts_version)
          entry = {
              "repo": name,
              "default_branch": branch,
              "scala_version": current,
              "compiler_flags": flags,
              "kind": kind,
              "open_upgrade_pr": None,
              "previous_pr": None,
              "needs_upgrade": kind in ("upgrade", "major_upgrade"),
              "deferred": False,
          }
          if entry["needs_upgrade"]:
              try:
                  prs = json.loads(get(f"https://api.github.com/repos/kchapl/{name}/pulls?state=all&per_page=100"))
              except Exception:
                  prs = []
              def target_version(pr):
                  m = re.search(r"Scala\s+(\d+\.\d+\.\d+)", pr.get("title") or "")
                  return m.group(1) if m else None

              for pr in prs:
                  if pr["head"]["ref"] != "scala-lts-upgrade":
                      continue
                  if pr["state"] == "open":
                      entry["open_upgrade_pr"] = {"number": pr["number"], "title": pr["title"], "url": pr["html_url"]}
                      break
                  # A merged or declined pull request only settles the release it
                  # targeted: an upgrade to an older LTS must not block the next one.
                  # A title this workflow did not write keeps the conservative answer.
                  if target_version(pr) not in (None, lts_version):
                      continue
                  if entry["previous_pr"] is None:
                      entry["previous_pr"] = {
                          "state": "pr_merged" if pr.get("merged_at") else "pr_closed",
                          "number": pr["number"],
                          "title": pr["title"],
                          "url": pr["html_url"],
                          "target": target_version(pr),
                      }
          plan.append(entry)

      limit_raw = (os.environ.get("GH_AW_INPUTS_MAX_REPOS") or "").strip()
      limit = min(int(limit_raw), 10) if limit_raw else 10
      eligible = [e for e in plan if e["needs_upgrade"] and e["open_upgrade_pr"] is None]
      for e in eligible[limit:]:
          e["deferred"] = True

      for e in plan:
          if e["open_upgrade_pr"]:
              e["status"] = "pr_open"
          elif e["previous_pr"]:
              e["status"] = e["previous_pr"]["state"]
          elif not e["needs_upgrade"]:
              e["status"] = e["kind"]
          elif e["deferred"]:
              e["status"] = "deferred"
          else:
              e["status"] = "pending"

      tracker = None
      try:
          repo_slug = os.environ["GITHUB_REPOSITORY"]
          for issue in json.loads(get(f"https://api.github.com/repos/{repo_slug}/issues?state=open&per_page=100")):
              if issue["title"].startswith("Scala LTS upgrade tracker"):
                  tracker = {"number": issue["number"], "url": issue["html_url"]}
                  break
      except Exception:
          pass
      json.dump({"tracker_issue": tracker}, open(f"{DATA}/tracker.json", "w"), indent=2)
      with open(f"{DATA}/pending.tsv", "w") as fh:
          for e in plan:
              if e["status"] == "pending":
                  fh.write(f"{e['repo']}\t{e['default_branch']}\n")

      json.dump(plan, open(f"{DATA}/plan.json", "w"), indent=2)
      print(f"target LTS {lts_version} (line {lts_line})")
      print(f"{'repo':32} {'current':10} status")
      for e in plan:
          print(f"{e['repo']:32} {str(e['scala_version']):10} {e['status']}")
      PY

      git config --global user.name "github-actions[bot]"
      git config --global user.email "41898282+github-actions[bot]@users.noreply.github.com"
      mkdir -p "$GITHUB_WORKSPACE/targets"
      while IFS=$'\t' read -r repo branch; do
        [ -z "$repo" ] && continue
        git clone --quiet --depth 1 --branch "$branch" "https://github.com/kchapl/$repo.git" "$GITHUB_WORKSPACE/targets/$repo"
        git -C "$GITHUB_WORKSPACE/targets/$repo" checkout --quiet -B scala-lts-upgrade
        echo "prepared $repo (base $branch)"
      done < /tmp/gh-aw/data/pending.tsv
safe-outputs:
  github-token: ${{ secrets.SCALA_LTS_PAT }}
  staged: ${{ inputs.dry_run == true }}
  mentions: false
  create-pull-request:
    draft: false
    max: 10
    preserve-branch-name: true
    recreate-ref: true
    protected-files: allowed
    max-patch-files: 50
    allowed-repos:
      - kchapl/ai-studio
      - kchapl/book-lamp
      - kchapl/catalyst
      - kchapl/dotfiles
      - kchapl/energy-analysis
      - kchapl/gh-mission
      - kchapl/greentech
      - kchapl/kchapl.github.io
      - kchapl/orchestration
      - kchapl/play-scala-seed
      - kchapl/rocket
      - kchapl/thickening-plot
      - kchapl/trajectory
      - kchapl/weather-forecast-accuracy
    allowed-files:
      - "**/*.sbt"
      - "**/*.scala"
      - "**/*.java"
      - "build.sc"
      - "mill-build/**"
      - "project/**"
      - "src/**"
  create-issue:
    title-prefix: "Scala LTS upgrade tracker"
    deduplicate-by-title: true
    max: 1
  update-issue:
    target: "*"
    body: true
    max: 1
---

# Scala LTS Upgrade

## Context

Current repository: `{{ github.repository }}`
Repository plan: `/tmp/gh-aw/data/plan.json`
Target release: `/tmp/gh-aw/data/lts.json`
Existing tracker issue: `/tmp/gh-aw/data/tracker.json`

Read all three files first. Each plan entry carries `repo`, `default_branch`, `scala_version`, `compiler_flags`, `kind`, `open_upgrade_pr`, `needs_upgrade`, `deferred`, and the pre-computed `status`.

Only entries with `status: pending` need work. Every other status is final for this run: `already_current`, `pr_open`, `pr_closed`, `pr_merged`, `deferred`, `no_scala_version`, `ahead_of_lts`, `unparsed_version`. A `pr_closed` entry means a human already declined an upgrade pull request **for this run's target release** on that branch; do not raise it again. The plan only reports `pr_closed` or `pr_merged` when the earlier pull request targeted the current `lts_version`, so a repository whose upgrade to an older LTS was merged or declined stays `pending` and still gets the newer release.

Entries with `kind: major_upgrade` are still on Scala 2 and need a migration, not a version bump. Entries with `kind: upgrade` are already on Scala 3 and need only a patch or minor bump.

## Task

Objective: bring every eligible Scala repository of `kchapl` onto the latest Scala LTS patch release, raising at most one pull request per repository.

Do not re-discover the repository list, the target release, or the existing upgrade pull requests. The plan is authoritative. Re-read a repository only to work on it.

### Per-repository procedure

Work through plan entries in order. Handle each repository completely before starting the next one.

1. **Skip without work** for every entry whose `status` is not `pending`. Record the status as-is; it becomes a row in the tracker.
2. **Work in the prepared checkout** at `$GITHUB_WORKSPACE/targets/<repo>`. It is already cloned on the default branch with the `scala-lts-upgrade` branch checked out. Every change must be committed there, because the pull request is built from those commits: `cd` into the checkout, run `git add -A`, then `git commit -m "Upgrade to Scala <lts_version> (LTS)"`. Do not create differently named branches and do not push.
3. **Install the toolchain once** and reuse it for later repositories. The target projects use sbt; install a JDK 21 and sbt if the runner lacks them, and use the project's own wrapper or `project/build.properties` version when it pins one.
4. **Change only what the upgrade requires**:
   - Set the Scala version to `lts_version` everywhere it is declared (`ThisBuild / scalaVersion`, per-project `scalaVersion`, and the module identifier suffix if the build hardcodes it).
   - Bump only those dependency or plugin versions that the new compiler cannot build against, and say which ones and why.
   - Do not reformat, refactor, rename, or modernise unrelated code. Do not touch CI configuration or workflow files.
#### Scala 2 migrations

For a `major_upgrade` entry the version bump alone will not compile. Treat it as a migration under a strict budget:

- Set the version to `lts_version` first, then let the compiler enumerate the breakage instead of pre-emptively rewriting code.
- `-source:3.0-migration` may be added to `scalacOptions` while the code is still being adapted, but remove it before finishing if the code compiles without it.
- Every dependency and sbt plugin must publish for Scala 3 (`_3` artifacts). If one does not, record `not_possible` naming the artifact and the version it would need.
- Prefer mechanical, local fixes. If the migration requires macro rewrites, implicit-conversion redesign, or a framework major upgrade, record `not_possible` with the blocking construct instead of attempting it.
- Say in the pull request body that this is a Scala 2 to Scala 3 migration and list the constructs you changed.

5. **Verify with warnings treated as errors**, without committing the flag:
   - `sbt "set ThisBuild/scalacOptions += \"-Werror\"" clean compile Test/compile`
   - then the project's test suite (`test` or the multi-module equivalent), under a per-repository timeout of about 15 minutes.
   - Treat any error, warning, or deprecation notice as a failure. Fix it at the source with the smallest possible change and re-verify. Stop after three fix attempts.
6. **Raise the pull request** only when the build and tests are green and the diff is confined to the allowed files:
   - Branch: `scala-lts-upgrade`
   - Title: `Upgrade to Scala <lts_version> (LTS)`, or `Migrate to Scala <lts_version> (LTS)` for a `major_upgrade` entry
   - Body: the previous and new Scala version, every changed file with a one-line reason, the exact verification commands, and their outcome.
   - Call `create_pull_request` with `repo` set to `kchapl/<repo>` and `branch` set to `scala-lts-upgrade`. The committed changes in that checkout are the patch; never paste file contents into the call.
   - Never open more than one pull request per repository and never reuse a different branch name.
7. **Record a failure honestly** when the upgrade cannot be completed: status `not_possible` plus one sentence naming the blocking error, warning or deprecation. Never open a pull request that does not build cleanly.

### Dry runs

In a staged dry run the platform records each safe output without applying it. Still emit every intended `create-pull-request` and tracker call so the preview shows exactly what a real run would do. Verification (clone, upgrade, build, test) still happens, because the point of a dry run is to prove the upgrade is real before anything is written.

### Deliverables

Publish one tracker issue in `{{ github.repository }}` titled `Scala LTS upgrade tracker`, updating the issue named in `tracker.json` when it already exists:

- `### Latest run` - date, target `lts_version`, run mode, and the number of repositories examined.
- `### Repository status` - one table row per plan entry: repository, previous version, resulting status, and the pull request link or failure reason.
- `### Summary` - counts for pull requests raised (separating Scala 3 upgrades from Scala 2 migrations), already current, upgrade pull request already open, upgrade declined or merged, not possible, ahead of LTS, and deferred by the run limit. The pull requests raised plus the not-possible count together answer how many eligible repositories received or failed to receive an upgrade.
- `### Problems` - the blocking error, warning or deprecation for each `not_possible` entry, collapsed in a `<details>` block when long.

On later runs, update the existing tracker issue instead of creating a second one. Keep the body self-contained: it should always describe the current state, not accumulate history.

Use `###` for top-level sections and `####` for subsections. Use GitHub-flavored alerts (`> [!NOTE]`, `> [!WARNING]`) instead of emojis, and do not add footer attribution.

## Safe Outputs

- Use `create-pull-request` for every repository upgrade, one call per repository, with `branch: scala-lts-upgrade`.
- Use `update-issue` with the number from `tracker.json` when the tracker already exists; otherwise use `create-issue` once.
- Never write directly to a target repository, never create issues there, and never push outside the safe-output path.

## No-op conditions

Call `noop` with a short reason when every plan entry is `already_current`, `pr_open`, `deferred`, or `no_scala_version`, and the tracker issue already reflects that state. Do not publish an empty report and do not open a repository for investigation when the plan says it needs none.
