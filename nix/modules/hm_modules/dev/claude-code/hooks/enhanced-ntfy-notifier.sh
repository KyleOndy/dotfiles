#!/usr/bin/env bash
# Desktop notification on Claude Code session end. Carries the project name,
# git branch and dirty state, and a tool-use summary read out of the transcript.

set -euo pipefail

BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() {
	echo -e "${BLUE}[enhanced-ntfy]${NC} $1" >&2
}

if ! command -v notify-send >/dev/null 2>&1; then
	log "notify-send not available, skipping notification"
	exit 0
fi

if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
	log "No display available, skipping notification"
	exit 0
fi

# Read JSON input from Claude Code
INPUT=$(cat)
log "Hook input received"

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

TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // ""')
CWD=$(echo "$INPUT" | jq -r '.cwd // ""')

if [ -n "$CWD" ]; then
	WORK_DIR="$CWD"
else
	WORK_DIR="$(pwd)"
fi

PROJECT_NAME=$(basename "$WORK_DIR")

GIT_BRANCH=""
GIT_STATUS=""
if git -C "$WORK_DIR" rev-parse --git-dir >/dev/null 2>&1; then
	GIT_BRANCH=$(git -C "$WORK_DIR" branch --show-current 2>/dev/null || echo "detached")

	if ! git -C "$WORK_DIR" diff-index --quiet HEAD -- 2>/dev/null; then
		GIT_STATUS="*"
	fi
fi

# Get session summary from transcript
SESSION_SUMMARY=""
if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
	# Count tool uses and extract key activities. Tool uses live nested in
	# assistant messages, not at the top level of the transcript JSONL.
	TOOL_FILTER='select(.type == "assistant") | .message.content[]? | select(.type == "tool_use") | .name'
	TOOL_COUNT=$(jq -r "$TOOL_FILTER" "$TRANSCRIPT_PATH" 2>/dev/null | wc -l)

	RECENT_TOOLS=$(jq -r "$TOOL_FILTER" "$TRANSCRIPT_PATH" 2>/dev/null | tail -3 | tr '\n' ',' | sed 's/,$//' || echo "")

	if [ "$TOOL_COUNT" -gt 0 ]; then
		SESSION_SUMMARY="Used $TOOL_COUNT tools"
		if [ -n "$RECENT_TOOLS" ]; then
			SESSION_SUMMARY="$SESSION_SUMMARY ($RECENT_TOOLS)"
		fi
	fi
fi

TIMESTAMP=$(date '+%H:%M')

if [ -n "$GIT_BRANCH" ]; then
	TITLE="Claude: $PROJECT_NAME ($GIT_BRANCH$GIT_STATUS)"
else
	TITLE="Claude: $PROJECT_NAME"
fi

MESSAGE="Session ended at $TIMESTAMP"
if [ -n "$SESSION_SUMMARY" ]; then
	MESSAGE="$MESSAGE • $SESSION_SUMMARY"
fi

URGENCY="low"
if [ -n "$GIT_STATUS" ]; then
	URGENCY="normal" # Uncommitted changes might be important
fi

notify-send \
	--app-name="Claude Code" \
	--icon="dialog-information" \
	--urgency="$URGENCY" \
	"$TITLE" \
	"$MESSAGE"

log "Notification sent: $TITLE | $MESSAGE"
