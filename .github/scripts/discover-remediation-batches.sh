#!/usr/bin/env bash
# Find open automated-health issues before allocating remediation workers.
# Outputs a GitHub Actions matrix of small repo/issue batches. Each batch runs
# sequentially on one worker so Docker images can be reused locally.
set -euo pipefail

REPOS_JSON=${REPOS_JSON:?REPOS_JSON must contain the discovered repository array}
OUTPUT_FILE=${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}
BATCH_SIZE=${BATCH_SIZE:-3}
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
if ((${#results[@]} == 0)); then
  printf 'matrix={"batch":["[]"]}\nhas_work=false\n' >>"$OUTPUT_FILE"
  echo "Found 0 repository/repositories requiring remediation"
  exit 0
fi
ELIGIBLE=$(jq -cs --argjson size "$BATCH_SIZE" '
  map(select(. != null)) as $repos
  | [range(0; ($repos | length); $size) as $i | $repos[$i:($i + $size)]]
' "${results[@]}")
COUNT=$(jq '[.[][]] | length' <<<"$ELIGIBLE")
BATCHES=$(jq -c 'if length == 0 then ["[]"] else map(tojson) end' <<<"$ELIGIBLE")
MATRIX=$(jq -cn --argjson batches "$BATCHES" '{batch: $batches}')
echo "Found $COUNT repository/repositories requiring remediation"
echo "matrix=$MATRIX" >>"$OUTPUT_FILE"
echo "has_work=$([[ $COUNT -gt 0 ]] && echo true || echo false)" >>"$OUTPUT_FILE"
