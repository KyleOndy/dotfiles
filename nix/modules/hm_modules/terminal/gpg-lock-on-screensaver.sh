#!/usr/bin/env bash
# Monitor for KDE screen lock and clear GPG/SSH caches

# Use dbus-monitor to watch for screen lock signals
dbus-monitor --session "type='signal',interface='org.freedesktop.ScreenSaver'" | while read -r line; do
	if echo "$line" | grep -q "boolean true"; then
		echo "Screen locked - clearing GPG and SSH caches"

		# Clear GPG agent cache, which ssh agent uses too
		echo RELOADAGENT | gpg-connect-agent >/dev/null 2>&1

		echo "Caches cleared"
	fi
done
