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
PERMISSION_MODE=""
if command -v jq >/dev/null 2>&1; then
	HOOK_EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // ""')
	NOTIFICATION_TYPE=$(echo "$INPUT" | jq -r '.notification_type // ""')
	PERMISSION_MODE=$(echo "$INPUT" | jq -r '.permission_mode // ""')
fi

set_state() {
	tmux set-option -p -t "$TMUX_PANE" @claude_state "$1" 2>/dev/null || true
}

case "$HOOK_EVENT" in
UserPromptSubmit)
	set_state RUN
	;;
PreToolUse)
	set_state EXE
	;;
PostToolUse)
	set_state RUN
	;;
PostToolUseFailure)
	set_state ERR
	;;
SubagentStart)
	set_state SUB
	;;
SubagentStop)
	set_state RUN
	;;
Stop)
	set_state IDL
	;;
Notification)
	if [ "$NOTIFICATION_TYPE" = "permission_prompt" ] &&
		[ "$PERMISSION_MODE" != "acceptEdits" ] &&
		[ "$PERMISSION_MODE" != "dontAsk" ] &&
		[ "$PERMISSION_MODE" != "bypassPermissions" ]; then
		set_state ASK
	fi
	;;
PreCompact)
	set_state CMP
	;;
SessionEnd)
	tmux set-option -p -u -t "$TMUX_PANE" @claude_state 2>/dev/null || true
	;;
esac

exit 0
