#!/usr/bin/env bash
# Find open automated-health issues before allocating remediation workers.
# Outputs a GitHub Actions matrix with one entry per affected repository, so a
# slow or failing remediation cannot hold up any other repository.
set -euo pipefail

REPOS_JSON=${REPOS_JSON:?REPOS_JSON must contain the discovered repository array}
OUTPUT_FILE=${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}
LOOKUP_CONCURRENCY=${LOOKUP_CONCURRENCY:-8}
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

lookup_issue() {
  local index=$1 repo=$2 issue
  if ! issue=$(gh issue list --repo "$repo" --label automated-health \
    --state open --limit 1 --json number --jq '.[0].number // empty'); then
    echo "::error::Could not check automated-health issues for $repo"
    return 1
  fi
  printf -v filename '%06d.json' "$index"
  jq -cn --arg repo "$repo" --arg issue "$issue" \
    'if $issue == "" then null else {repo: $repo, issue: ($issue | tonumber)} end' \
    >"$TEMP_DIR/$filename"
}

pids=()
index=0
failed=0
while IFS= read -r repo; do
  [[ -n $repo ]] || continue
  lookup_issue "$index" "$repo" &
  pids+=("$!")
  index=$((index + 1))
  if ((${#pids[@]} >= LOOKUP_CONCURRENCY)); then
    wait "${pids[0]}" || failed=1
    pids=("${pids[@]:1}")
  fi
done < <(jq -r '.repo[]' <<<"$REPOS_JSON")

for pid in "${pids[@]}"; do
  wait "$pid" || failed=1
done
((failed == 0)) || exit 1

shopt -s nullglob
results=("$TEMP_DIR"/*.json)
MATRIX=$(jq -cs '{include: map(select(. != null))}' "${results[@]}")
COUNT=$(jq '.include | length' <<<"$MATRIX")
echo "Found $COUNT repository/repositories requiring remediation"

# An empty include list is not a valid matrix. Keep a placeholder entry; the
# resolve-issues job is skipped by its has_work condition, not by the matrix.
if ((COUNT == 0)); then
  MATRIX='{"include":[{"repo":"","issue":0}]}'
fi
echo "matrix=$MATRIX" >>"$OUTPUT_FILE"
echo "has_work=$([[ $COUNT -gt 0 ]] && echo true || echo false)" >>"$OUTPUT_FILE"
