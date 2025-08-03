#!/usr/bin/env bash
# Claude Code notification hook - plays a custom notification sound

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Path to the notification sound
SOUND_FILE="$PROJECT_ROOT/assets/notification.wav"

# Play custom notification sound
if [ -f "$SOUND_FILE" ]; then
    # Use ffplay (quiet mode, no video window)
    ffplay -nodisp -autoexit -loglevel quiet "$SOUND_FILE" 2>/dev/null &

    # Alternative: Use cvlc if ffplay doesn't work
    # cvlc --play-and-exit --intf dummy "$SOUND_FILE" 2>/dev/null &
else
    # Fallback to terminal bell if sound file not found
    echo "Warning: Sound file not found at $SOUND_FILE, using terminal bell" >&2
    echo -e '\a'
fi

exit 0 # Exit successfully
