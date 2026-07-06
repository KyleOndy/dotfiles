#!/usr/bin/env bash
# Claude Code notification hook - plays a custom notification sound
# Automatically lowers volume when meeting apps are running

set -euo pipefail

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
