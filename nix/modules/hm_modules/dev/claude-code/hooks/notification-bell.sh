#!/usr/bin/env bash
# Claude Code notification hook - plays a custom notification sound
# Automatically lowers volume when meeting apps are running

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

# Path to the notification sound (env-overridable; the script is packaged
# into its own store path, so it can't locate the wav relative to itself)
SOUND_FILE="${SOUND_FILE:-$HOME/.claude/assets/notification.wav}"

# Lower volume during active Zoom calls (macOS only: CptHost is Zoom's
# in-meeting helper process; it only spawns during an active call)
VOLUME_FACTOR=1.0
if pgrep -if "CptHost" >/dev/null 2>&1; then
	VOLUME_FACTOR=0.3
fi

# Play custom notification sound; fall back to the terminal bell if the
# sound file or player is missing, or if playback fails
if [ -f "$SOUND_FILE" ] && command -v ffplay >/dev/null 2>&1; then
	(
		ffplay -nodisp -autoexit -loglevel quiet \
			-af "volume=${VOLUME_FACTOR}" \
			"$SOUND_FILE" || printf '\a'
	) &
else
	echo "Warning: cannot play $SOUND_FILE, using terminal bell" >&2
	printf '\a'
fi

exit 0
