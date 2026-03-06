#!/usr/bin/env bash
set -euo pipefail

# Not in tmux → no-op
if [ -z "${TMUX:-}" ] || [ -z "${TMUX_PANE:-}" ]; then
	exit 0
fi

command -v tmux >/dev/null 2>&1 || exit 0

INPUT=$(cat)
HOOK_EVENT=""
if command -v jq >/dev/null 2>&1; then
	HOOK_EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // ""')
fi

WINDOW_ID=$(tmux display-message -t "$TMUX_PANE" -p '#{window_id}' 2>/dev/null) || exit 0

case "$HOOK_EVENT" in
Stop)
	tmux set-option -w -t "$WINDOW_ID" @claude_state waiting 2>/dev/null || true
	;;
SessionEnd)
	tmux set-option -w -t "$WINDOW_ID" @claude_state "done" 2>/dev/null || true
	;;
UserPromptSubmit)
	tmux set-option -wu -t "$WINDOW_ID" @claude_state 2>/dev/null || true
	;;
esac

exit 0
