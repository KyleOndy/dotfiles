#!/usr/bin/env bash
set -euo pipefail

# Query Tdarr API for failed jobs and extract actual error messages from logs
# Usage: tdarr-failure-summary.sh [days_back]

TDARR_URL="${TDARR_URL:-http://127.0.0.1:8265}"
DAYS_BACK="${1:-7}"
API_KEY_FILE="${TDARR_API_KEY_FILE:-}"
LOG_BASE_DIR="${TDARR_LOG_DIR:-/var/lib/tdarr/server/Tdarr/DB2/JobReports}"

# Build auth header
AUTH_ARGS=()
if [[ -n "$API_KEY_FILE" && -f "$API_KEY_FILE" ]]; then
    API_KEY=$(cat "$API_KEY_FILE")
    AUTH_ARGS=(-H "x-api-key: $API_KEY")
fi

# Calculate cutoff date (epoch seconds in milliseconds - Tdarr uses milliseconds)
CUTOFF_DATE=$(date -d "-$DAYS_BACK days" +%s)000

echo "=== Tdarr Failure Summary (last $DAYS_BACK days) ==="
echo ""

# Function to extract error message from job log file
extract_error() {
    local footprint_id="$1"
    local file_id="$2"
    local log_file="$LOG_BASE_DIR/$footprint_id/$file_id"

    if [[ ! -f "$log_file" ]]; then
        echo "log file not found"
        return
    fi

    # Extract error from log - look for common error patterns
    # Try multiple patterns and return the first match
    local error=""

    # Pattern 1: Lines with [-error-] marker
    error=$(grep -i '\[-error-\]' "$log_file" 2>/dev/null | tail -1 | sed 's/.*\[-error-\]//' | xargs || true)

    # Pattern 2: Lines starting with "Error:"
    if [[ -z "$error" ]]; then
        error=$(grep -i '^Error:' "$log_file" 2>/dev/null | head -1 | sed 's/^Error: *//' || true)
    fi

    # Pattern 3: Look for "Flow has failed" context
    if [[ -z "$error" ]]; then
        error=$(grep -B 2 -i 'Flow has failed' "$log_file" 2>/dev/null | grep -i 'error' | head -1 | xargs || true)
    fi

    # Pattern 4: Look for "Transcode.*error" context
    if [[ -z "$error" ]]; then
        error=$(grep -i 'transcode.*error' "$log_file" 2>/dev/null | head -1 | xargs || true)
    fi

    # Fallback: Get last non-empty line
    if [[ -z "$error" ]]; then
        error=$(grep -v '^$' "$log_file" 2>/dev/null | tail -1 || true)
    fi

    # Truncate to 150 characters
    if [[ ${#error} -gt 150 ]]; then
        error="${error:0:147}..."
    fi

    echo "${error:-no error details found}"
}

# Fetch jobs with pagination
PAGE_SIZE=100
START=0
ALL_JOBS=""

while true; do
    RESPONSE=$(curl -s -X POST "$TDARR_URL/api/v2/client/jobs" \
        -H "Content-Type: application/json" \
        "${AUTH_ARGS[@]}" \
        -d "{\"data\":{\"filters\":[],\"sorts\":[{\"id\":\"start\",\"desc\":true}],\"opts\":{},\"pageSize\":$PAGE_SIZE,\"start\":$START}}")

    JOBS=$(echo "$RESPONSE" | jq -r '.array // []')
    TOTAL_COUNT=$(echo "$RESPONSE" | jq -r '.totalCount // 0')

    if [[ "$JOBS" == "[]" ]] || [[ "$JOBS" == "null" ]]; then
        break
    fi

    if [[ -z "$ALL_JOBS" ]]; then
        ALL_JOBS="$JOBS"
    else
        ALL_JOBS=$(echo "$ALL_JOBS" | jq --argjson new "$JOBS" '. + $new')
    fi

    START=$((START + PAGE_SIZE))

    # Stop if we've fetched all jobs or enough to cover the date range
    if [[ $START -ge $TOTAL_COUNT ]]; then
        break
    fi
done

# Process failed jobs
echo "--- Recent Failures ---"

if [[ -z "$ALL_JOBS" ]] || [[ "$ALL_JOBS" == "[]" ]]; then
    echo "No jobs found"
else
    echo "$ALL_JOBS" | jq -r --arg cutoff "$CUTOFF_DATE" '
      .[] |
      select(.status == "Transcode error" or .status == "Error") |
      select((.start // 0) > ($cutoff | tonumber)) |
      [
        (.start | . / 1000 | strftime("%Y-%m-%d")),
        .file,
        .job.footprintId,
        .job.fileId
      ] | @tsv
    ' 2>/dev/null | while IFS=$'\t' read -r date file footprint_id file_id; do
        error=$(extract_error "$footprint_id" "$file_id")
        echo "$date | $file | $error"
    done | sort -r || true
fi

echo ""
