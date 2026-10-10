#!/usr/bin/env bash
set -euo pipefail

# Not in tmux → no-op
if [ -z "${TMUX:-}" ] || [ -z "${TMUX_PANE:-}" ]; then
	exit 0
fi

command -v tmux >/dev/null 2>&1 || exit 0

HOOK_EVENT=""
NOTIFICATION_TYPE=""
PERMISSION_MODE=""
# Set only when the hook fires inside a subagent.
AGENT_ID=""
# "true" when Stop's background_tasks holds a shell or subagent still in
# progress. As of 2.1.288 it lists every such task in the session, not only
# the turn's own as the hooks docs say.
BACKGROUND=""
if command -v jq >/dev/null 2>&1; then
	# Unit separator, not tab: read collapses runs of whitespace IFS, which
	# would shift fields whenever one is empty.
	IFS=$'\x1f' read -r HOOK_EVENT NOTIFICATION_TYPE PERMISSION_MODE AGENT_ID BACKGROUND < <(
		jq -r '[.hook_event_name, .notification_type, .permission_mode, .agent_id,
			(any(.background_tasks[]?; .status == "pending" or .status == "running") | tostring)]
			| map(. // "") | join("\u001f")'
	) || true
fi

set_state() {
	tmux set-option -p -t "$TMUX_PANE" @claude_state "$1" 2>/dev/null || true
}

case "$HOOK_EVENT" in
SessionStart)
	# Clear stale state left by a predecessor that died without SessionEnd
	# (killed terminal, OOM); only SessionEnd unsets the pane variable.
	set_state IDL
	;;
UserPromptSubmit)
	set_state RUN
	;;
PreToolUse)
	set_state EXE
	;;
PostToolUse | PostToolUseFailure)
	# A subagent's call leaves it still working, often after the main
	# conversation's Stop, and is the only event that follows a permission
	# prompt it raised.
	if [ -n "$AGENT_ID" ]; then
		set_state EXE
	elif [ "$HOOK_EVENT" = PostToolUse ]; then
		set_state RUN
	else
		set_state ERR
	fi
	;;
SubagentStart)
	set_state SUB
	;;
# No SubagentStop: a subagent's result reaches the main conversation as a
# UserPromptSubmit that ends in Stop. Claude Code also fires SubagentStop for
# an internal agent it runs after Stop, which has no SubagentStart.
Stop)
	if [ "$BACKGROUND" = true ]; then
		set_state EXE
	else
		set_state IDL
	fi
	;;
StopFailure)
	set_state FAIL
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
PostCompact)
	set_state RUN
	;;
SessionEnd)
	tmux set-option -p -u -t "$TMUX_PANE" @claude_state 2>/dev/null || true
	;;
esac

exit 0
