#!/usr/bin/env bash
# Claude Code notification hook: plays notification-bell unless the
# notification is one Claude is not waiting on you for.

set -euo pipefail

# idle_prompt fires a minute after every turn, including one that ends with a
# Monitor or background shell still running: Claude Code holds it back only
# for background subagents. tmux-indicator.sh records that case as EXE on Stop,
# and Claude is not waiting on you then.
NOTIFICATION_TYPE="$(jq -r '.notification_type // ""')"
if [ "$NOTIFICATION_TYPE" = idle_prompt ] && [ -n "${TMUX_PANE:-}" ] &&
	[ "$(tmux show-options -p -v -t "$TMUX_PANE" @claude_state 2>/dev/null)" = EXE ]; then
	exit 0
fi

exec notification-bell
