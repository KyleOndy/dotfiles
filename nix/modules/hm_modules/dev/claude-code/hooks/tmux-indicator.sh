#!/usr/bin/env bash
set -euo pipefail

# Not in tmux → no-op
if [ -z "${TMUX:-}" ] || [ -z "${TMUX_PANE:-}" ]; then
	exit 0
fi

command -v tmux >/dev/null 2>&1 || exit 0

INPUT=$(cat)
HOOK_EVENT=""
NOTIFICATION_TYPE=""
if command -v jq >/dev/null 2>&1; then
	HOOK_EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // ""')
	NOTIFICATION_TYPE=$(echo "$INPUT" | jq -r '.notification_type // ""')
fi

case "$HOOK_EVENT" in
Stop)
	tmux set-option -p -t "$TMUX_PANE" @claude_state waiting 2>/dev/null || true
	;;
SessionEnd)
	tmux set-option -p -u -t "$TMUX_PANE" @claude_state 2>/dev/null || true
	;;
UserPromptSubmit)
	tmux set-option -p -t "$TMUX_PANE" @claude_state working 2>/dev/null || true
	;;
Notification)
	if [ "$NOTIFICATION_TYPE" = "permission_prompt" ]; then
		tmux set-option -p -t "$TMUX_PANE" @claude_state waiting 2>/dev/null || true
	fi
	;;
esac

exit 0
