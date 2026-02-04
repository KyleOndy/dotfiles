#!/usr/bin/env bash
# Claude Code notification hook - plays a custom notification sound
# Automatically lowers volume when meeting apps are running

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Path to the notification sound
SOUND_FILE="$PROJECT_ROOT/assets/notification.wav"

# Check if any meeting/communication app is running and lower volume
VOLUME_FACTOR=1.0
for app in zoom teams; do
	if pgrep -i "$app" >/dev/null 2>&1; then
		VOLUME_FACTOR=0.3 # 30% volume when in a meeting
		break
	fi
done

# Play custom notification sound
if [ -f "$SOUND_FILE" ]; then
	# Use ffplay (quiet mode, no video window, with volume adjustment)
	ffplay -nodisp -autoexit -loglevel quiet \
		-af "volume=${VOLUME_FACTOR}" \
		"$SOUND_FILE" 2>/dev/null &

	# Alternative: Use cvlc if ffplay doesn't work
	# cvlc --play-and-exit --intf dummy "$SOUND_FILE" 2>/dev/null &
else
	# Fallback to terminal bell if sound file not found
	echo "Warning: Sound file not found at $SOUND_FILE, using terminal bell" >&2
	echo -e '\a'
fi

exit 0 # Exit successfully
