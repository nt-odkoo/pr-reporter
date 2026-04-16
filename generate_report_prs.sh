#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# PR Daily Report Generator
# Usage: ./generate-report.sh --date 2026-04-15
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOS_CONF="${SCRIPT_DIR}/conf/repos.conf"
IGNORE_CONF="${SCRIPT_DIR}/conf/ignore_users.conf"
REPORTS_DIR="${SCRIPT_DIR}/reports"
DEBUG_DIR="${SCRIPT_DIR}/debug"
LIMIT=30
MODEL="gemini-2.5-flash"

DATE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --date|-d)
            DATE="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 --date YYYY-MM-DD"
            echo ""
            echo "Generates a daily PR report for the given date."
            echo ""
            echo "Options:"
            echo "  --date, -d    Date to generate report for (YYYY-MM-DD)"
            echo "  --help, -h    Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

if [[ -z "$DATE" ]]; then
    echo "Error: --date is required. Usage: $0 --date YYYY-MM-DD"
    exit 1
fi

# Validate date format
if ! [[ "$DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    echo "Error: Invalid date format. Use YYYY-MM-DD"
    exit 1
fi

# ---------- Validate config files ----------
if [[ ! -f "$REPOS_CONF" ]]; then
    echo "Error: Repos config not found at $REPOS_CONF"
    echo "Create it with one repo per line, e.g.:"
    echo "  org/repo-name"
    exit 1
fi

if [[ ! -f "$IGNORE_CONF" ]]; then
    echo "Warning: Ignore config not found at $IGNORE_CONF, no authors will be ignored."
    touch "$IGNORE_CONF"
fi

mkdir -p "$REPORTS_DIR"
mkdir -p "$DEBUG_DIR"

REPORT_FILE="${REPORTS_DIR}/daily-report-${DATE}.md"

# ---------- Load configs ----------
mapfile -t REPOS < <(grep -v '^\s*#' "$REPOS_CONF" | grep -v '^\s*$')
mapfile -t IGNORED_AUTHORS < <(grep -v '^\s*#' "$IGNORE_CONF" | grep -v '^\s*$' | tr '[:upper:]' '[:lower:]')

if [[ ${#REPOS[@]} -eq 0 ]]; then
    echo "Error: No repos found in $REPOS_CONF"
    exit 1
fi

# ---------- Helper: check if author is ignored ----------
is_ignored() {
    local author
    author=$(echo "$1" | tr '[:upper:]' '[:lower:]')
    for ignored in "${IGNORED_AUTHORS[@]}"; do
        if [[ "$author" == "$ignored" ]]; then
            return 0
        fi
    done
    return 1
}

# ---------- Helper: strip CodeRabbit / bot noise from PR body ----------
strip_bot_noise() {
    local body="$1"
    echo "$body" | sed \
        -e '/<!-- *This is an auto-generated comment.*coderabbit/,$d' \
        -e '/^## Summary by CodeRabbit/,$d' \
        -e '/^## Walkthrough/,$d' \
        -e '/^## Visual Changes/I,$d' \
        -e '/^<!-- *coderabbitai/,$d' \
        -e '/@coderabbitai/d'
}

# ---------- Helper: generate summary via Gemini CLI ----------
generate_summary() {
    local prompt="$1"
    
    if command -v gemini &>/dev/null; then
        echo "$prompt" | gemini --model $MODEL 2>/dev/null || echo "_Summary generation failed_"
    else
        echo "_Gemini CLI not installed."
    fi
}

# ---------- Helper: build jq ignore filter ----------
# Builds a jq expression that filters out comments from ignored authors
build_jq_ignore_filter() {
    if [[ ${#IGNORED_AUTHORS[@]} -eq 0 ]]; then
        echo "true"
        return
    fi
    # Build: (.user.login | ascii_downcase) as $u | ($u != "bot1" and $u != "bot2")
    local conditions=""
    for author in "${IGNORED_AUTHORS[@]}"; do
        if [[ -n "$conditions" ]]; then
            conditions+=" and "
        fi
        conditions+="\$u != \"${author}\""
    done
    echo "(.user.login | ascii_downcase) as \$u | (${conditions})"
}

# ---------- Helper: fetch PR comments ----------
fetch_pr_comments() {
    local repo="$1"
    local pr_number="$2"
    local jq_filter
    jq_filter=$(build_jq_ignore_filter)
    
    # Issue comments (general PR comments) — filtered
    local issue_comments
    issue_comments=$(gh api "repos/${repo}/issues/${pr_number}/comments" \
        --jq ".[] | select(${jq_filter}) | .body" 2>/dev/null || echo "")
    
    # Review comments (inline code comments) — filtered
    local review_comments
    review_comments=$(gh api "repos/${repo}/pulls/${pr_number}/comments" \
        --jq ".[] | select(${jq_filter}) | .body" 2>/dev/null || echo "")
    
    # Reviews (review body text) — filtered
    local reviews
    reviews=$(gh api "repos/${repo}/pulls/${pr_number}/reviews" \
        --jq ".[] | select(.body != null and .body != \"\") | select(${jq_filter}) | .body" 2>/dev/null || echo "")
    
    echo "${issue_comments}"$'\n'"${review_comments}"$'\n'"${reviews}"
}

# ---------- Main logic ----------
echo "========================================="
echo " PR Daily Report Generator"
echo " Date: ${DATE}"
echo "========================================="
echo ""

# Initialize report
cat > "$REPORT_FILE" << EOF
# Daily PR Report — ${DATE}

_Generated at $(date '+%Y-%m-%d %H:%M:%S')_

---

EOF

TOTAL_PRS=0
HAS_CONTENT=false

for REPO in "${REPOS[@]}"; do
    echo "Processing repo: ${REPO}..."
    
    # Fetch all PRs updated on the given date (any state)
    # gh search prs returns PRs updated on a specific date
    PRS_JSON=$(gh pr list \
        --repo "$REPO" \
        --state all \
        --search "updated:${DATE}" \
        --json number,title,url,state,author,body \
        --limit "$LIMIT" 2>/dev/null || echo "[]")
    
    if [[ "$PRS_JSON" == "[]" || -z "$PRS_JSON" ]]; then
        echo "  No PRs found for ${REPO} on ${DATE}"
        continue
    fi
    
    # Group PRs by author
    AUTHORS=$(echo "$PRS_JSON" | jq -r '.[].author.login' | sort -u)
    
    REPO_HAS_CONTENT=false
    
    for AUTHOR in $AUTHORS; do
        # Skip ignored authors
        if is_ignored "$AUTHOR"; then
            echo "  Skipping ignored author: ${AUTHOR}"
            continue
        fi
        
        # Get this author's PRs
        AUTHOR_PRS=$(echo "$PRS_JSON" | jq -c --arg author "$AUTHOR" '[.[] | select(.author.login == $author)]')
        PR_COUNT=$(echo "$AUTHOR_PRS" | jq 'length')
        
        if [[ "$PR_COUNT" -eq 0 ]]; then
            continue
        fi
        
        REPO_HAS_CONTENT=true
        HAS_CONTENT=true
        TOTAL_PRS=$((TOTAL_PRS + PR_COUNT))
        
        echo "  Author: ${AUTHOR} (${PR_COUNT} PRs)"
        
        # ---------- Build context for Gemini summary ----------
        SUMMARY_INPUT="Summarize what this developer has been working on based on these Pull Requests. Be concise (3-7 sentences max). Output ONLY the summary in English, no extra formatting.\n\n"
        
        # Build PR table rows and collect summary material
        TABLE_ROWS=""
        
        while IFS= read -r pr_item; do
            PR_NUMBER=$(echo "$pr_item" | jq -r '.number')
            PR_TITLE=$(echo "$pr_item" | jq -r '.title')
            PR_URL=$(echo "$pr_item" | jq -r '.url')
            PR_STATE=$(echo "$pr_item" | jq -r '.state')
            PR_AUTHOR=$(echo "$pr_item" | jq -r '.author.login')
            PR_BODY=$(echo "$pr_item" | jq -r '.body // ""' | head -c 3000)

            # Strip CodeRabbit auto-generated sections from PR body
            PR_BODY=$(strip_bot_noise "$PR_BODY" | head -c 1000)
            
            # Map state to display format
            case "$PR_STATE" in
                MERGED) STATUS="✅ Merged" ;;
                OPEN)   STATUS="🔵 Open" ;;
                CLOSED) STATUS="🔴 Closed" ;;
                *)      STATUS="$PR_STATE" ;;
            esac
            
            # Fetch comments for this PR
            echo "    Fetching comments for PR #${PR_NUMBER}..."
            COMMENTS=$(fetch_pr_comments "$REPO" "$PR_NUMBER")
            
            # Append to summary input
            SUMMARY_INPUT+="PR #${PR_NUMBER}: ${PR_TITLE}\n"
            if [[ -n "$PR_BODY" && "$PR_BODY" != "null" ]]; then
                SUMMARY_INPUT+="Description: ${PR_BODY}\n"
            fi
            if [[ -n "$COMMENTS" ]]; then
                # Truncate comments to avoid overly long input
                TRUNCATED_COMMENTS=$(strip_bot_noise "$COMMENTS" | head -c 2000)
                SUMMARY_INPUT+="Comments: ${TRUNCATED_COMMENTS}\n"
            fi
            SUMMARY_INPUT+="\n"
            
            # Build table row
            # TABLE_ROWS+="| [#${PR_NUMBER}](${PR_URL}) | ${STATUS} | ${PR_TITLE} |"$'\n'
            TABLE_ROWS+="| [#${PR_NUMBER}](${PR_URL}) | ${STATUS} | ${PR_TITLE} | @${PR_AUTHOR} |"$'\n'
            
        done < <(echo "$AUTHOR_PRS" | jq -c '.[]')

        # ---------- Dump summary input to debug file ----------
        DEBUG_FILE="${DEBUG_DIR}/${DATE}_${REPO//\//_}_${AUTHOR}.txt"
        echo -e "$SUMMARY_INPUT" > "$DEBUG_FILE"
        echo "    Debug: summary input saved to ${DEBUG_FILE}"
        
        # ---------- Generate summary ----------
        echo "    Generating summary..."
        SUMMARY=$(generate_summary "$(echo -e "$SUMMARY_INPUT")")
        
        # ---------- Write to report ----------
        cat >> "$REPORT_FILE" << EOF
## ${REPO} — ${AUTHOR}

**Summary:** ${SUMMARY}

| Link | Status | Title | Created by |
|------|--------|-------|------------|
${TABLE_ROWS}
EOF
        
    done
    
    if [[ "$REPO_HAS_CONTENT" == false ]]; then
        echo "  No relevant PRs for ${REPO} on ${DATE} (all authors may be ignored)"
    fi
    
done

# ---------- Footer ----------
cat >> "$REPORT_FILE" << EOF
---

_Total PRs: ${TOTAL_PRS}_
EOF

if [[ "$HAS_CONTENT" == false ]]; then
    echo ""
    echo "No PRs found for any repo on ${DATE}."
    # Clean up empty report
    rm -f "$REPORT_FILE"
    exit 0
fi

echo ""
echo "========================================="
echo " Report generated: ${REPORT_FILE}"
echo " Total PRs: ${TOTAL_PRS}"
echo "========================================="
