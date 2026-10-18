#!/usr/bin/env bash
set -e

# Ensure gh CLI is installed and authenticated
if ! command -v gh &> /dev/null; then
    echo "Error: GitHub CLI (gh) is not installed."
    exit 1
fi

echo "=== Fetching all non-archived repositories ==="
# Fetch non-archived repos for the authenticated user
REPOS=$(gh api user/repos --paginate --jq '[.[] | select(.archived == false) | .full_name]')

CUTOFF_DATE=$(date -d '1 year ago' +%s)

declare -A LANG_COUNT
ARCHIVAL_CANDIDATES=()

echo "Auditing $(echo "$REPOS" | jq 'length') repositories..."
echo ""

for repo in $(echo "$REPOS" | jq -r '.[]'); do
    # Fetch repository primary language and details
    REPO_INFO=$(gh api "repos/$repo" --jq '{language: .language, updated_at: .pushed_at}')
    PRIMARY_LANG=$(echo "$REPO_INFO" | jq -r '.language // "Other/Unspecified"')

    # Increment language counter
    LANG_COUNT["$PRIMARY_LANG"]=$((${LANG_COUNT["$PRIMARY_LANG"]:-0} + 1))

    # Fetch last human commit (filtering out bots)
    LAST_HUMAN_COMMIT=$(gh api "repos/$repo/commits?per_page=15" --jq '
      [.[] | select(.author.type == "User" and (.author.login | contains("bot") | not))] 
      | .[0].commit.committer.date
    ' 2>/dev/null || echo "")

    if [ -n "$LAST_HUMAN_COMMIT" ] && [ "$LAST_HUMAN_COMMIT" != "null" ]; then
        COMMIT_TS=$(date -d "$LAST_HUMAN_COMMIT" +%s)
        if [ "$COMMIT_TS" -lt "$CUTOFF_DATE" ]; then
            HUMAN_DATE=$(date -d "$LAST_HUMAN_COMMIT" +%Y-%m-%d)
            ARCHIVAL_CANDIDATES+=("$repo (Last human commit: $HUMAN_DATE)")
        fi
    else
        ARCHIVAL_CANDIDATES+=("$repo (No human commits in recent history)")
    fi
done

echo "================================================="
echo "               LANGUAGE BREAKDOWN                "
echo "================================================="
for lang in "${!LANG_COUNT[@]}"; do
    printf "%-20s : %d repos\n" "$lang" "${LANG_COUNT[$lang]}"
done

echo ""
echo "================================================="
echo "   ARCHIVAL CANDIDATES (No Human Commits > 1 Year)"
echo "================================================="
if [ ${#ARCHIVAL_CANDIDATES[@]} -eq 0 ]; then
    echo "No candidate repositories found."
else
    for candidate in "${ARCHIVAL_CANDIDATES[@]}"; do
        echo " - $candidate"
    done
fi
