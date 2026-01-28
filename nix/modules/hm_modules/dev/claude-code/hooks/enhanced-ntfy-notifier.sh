#!/usr/bin/env bash
# Enhanced desktop notification hook for Claude Code
# Provides rich context including git info and session summary

set -euo pipefail

# Colors for output
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Log function
log() {
	echo -e "${BLUE}[enhanced-ntfy]${NC} $1" >&2
}

# Check if notifications are available
if ! command -v notify-send >/dev/null 2>&1; then
	log "notify-send not available, skipping notification"
	exit 0
fi

# Check if we're in a desktop environment
if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
	log "No display available, skipping notification"
	exit 0
fi

# Read JSON input from Claude Code
INPUT=$(cat)
log "Received hook input: $INPUT"

# Parse JSON input (requires jq)
if ! command -v jq >/dev/null 2>&1; then
	log "jq not available, falling back to basic notification"
	PROJECT_NAME=$(basename "$(pwd)")
	notify-send \
		--app-name="Claude Code" \
		--icon="dialog-information" \
		--urgency=low \
		"Claude Code Session Ended" \
		"Finished working in project: $PROJECT_NAME"
	exit 0
fi

# Extract data from JSON
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // ""')
CWD=$(echo "$INPUT" | jq -r '.cwd // ""')

# Use CWD if provided, otherwise use current directory
if [ -n "$CWD" ]; then
	WORK_DIR="$CWD"
else
	WORK_DIR="$(pwd)"
fi

# Get project context
PROJECT_NAME=$(basename "$WORK_DIR")

# Get git information
GIT_BRANCH=""
GIT_STATUS=""
if git -C "$WORK_DIR" rev-parse --git-dir >/dev/null 2>&1; then
	GIT_BRANCH=$(git -C "$WORK_DIR" branch --show-current 2>/dev/null || echo "detached")

	# Check for uncommitted changes
	if ! git -C "$WORK_DIR" diff-index --quiet HEAD -- 2>/dev/null; then
		GIT_STATUS="*" # Indicates changes
	fi
fi

# Get session summary from transcript
SESSION_SUMMARY=""
if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
	# Count tool uses and extract key activities
	TOOL_COUNT=$(jq -r 'select(.type == "tool_use") | .tool_name' "$TRANSCRIPT_PATH" 2>/dev/null | wc -l || echo "0")

	# Get last few tool uses for context
	RECENT_TOOLS=$(jq -r 'select(.type == "tool_use") | .tool_name' "$TRANSCRIPT_PATH" 2>/dev/null | tail -3 | tr '\n' ',' | sed 's/,$//' || echo "")

	if [ "$TOOL_COUNT" -gt 0 ]; then
		SESSION_SUMMARY="Used $TOOL_COUNT tools"
		if [ -n "$RECENT_TOOLS" ]; then
			SESSION_SUMMARY="$SESSION_SUMMARY ($RECENT_TOOLS)"
		fi
	fi
fi

# Get session duration (estimate from session ID timestamp if possible)
TIMESTAMP=$(date '+%H:%M')

# Build notification title and message
if [ -n "$GIT_BRANCH" ]; then
	TITLE="Claude: $PROJECT_NAME ($GIT_BRANCH$GIT_STATUS)"
else
	TITLE="Claude: $PROJECT_NAME"
fi

MESSAGE="Session ended at $TIMESTAMP"
if [ -n "$SESSION_SUMMARY" ]; then
	MESSAGE="$MESSAGE • $SESSION_SUMMARY"
fi

# Choose urgency based on context
URGENCY="low"
if [ -n "$GIT_STATUS" ]; then
	URGENCY="normal" # Uncommitted changes might be important
fi

# Send enhanced notification
notify-send \
	--app-name="Claude Code" \
	--icon="dialog-information" \
	--urgency="$URGENCY" \
	"$TITLE" \
	"$MESSAGE"

log "Enhanced notification sent: $TITLE | $MESSAGE"
