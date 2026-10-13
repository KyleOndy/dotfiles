#!/usr/bin/env bash
set -euo pipefail

# Plays the notification sound without waiting for it to finish.
# Usage: notification-bell

readonly SOUND_FILE="@sound@"

# Lower volume during active Zoom calls (macOS only: CptHost is Zoom's
# in-meeting helper process; it only spawns during an active call)
VOLUME_FACTOR=1.0
if pgrep -if "CptHost" >/dev/null 2>&1; then
	VOLUME_FACTOR=0.3
fi

ffplay -nodisp -autoexit -loglevel quiet -af "volume=${VOLUME_FACTOR}" "$SOUND_FILE" &
