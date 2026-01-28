#!/usr/bin/env bash
# Desktop notification hook for Claude Code
# Sends notifications when Claude Code sessions end

set -euo pipefail

# Colors for output
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Log function
log() {
	echo -e "${BLUE}[ntfy-notifier]${NC} $1" >&2
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

# Get current directory name for context
PROJECT_NAME=$(basename "$(pwd)")

# Send notification
notify-send \
	--app-name="Claude Code" \
	--icon="dialog-information" \
	--urgency=low \
	"Claude Code Session Ended" \
	"Finished working in project: $PROJECT_NAME"

log "Desktop notification sent for project: $PROJECT_NAME"
