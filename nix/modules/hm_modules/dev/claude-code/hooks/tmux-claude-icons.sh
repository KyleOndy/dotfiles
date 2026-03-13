#!/usr/bin/env bash
set -euo pipefail

# Aggregates per-pane Claude state icons for a given tmux window.
# Usage: tmux-claude-icons.sh <window_id>
# Called from tmux status format via #().

WINDOW_ID="${1:-}"
[ -n "$WINDOW_ID" ] || exit 0
command -v tmux >/dev/null 2>&1 || exit 0

icons=""

while IFS= read -r pane_id; do
	state=$(tmux show-option -p -t "$pane_id" -v @claude_state 2>/dev/null) || continue
	[ -n "$state" ] || continue
	[ -n "$icons" ] && icons="${icons} "
	icons="${icons}cc:${state}"
done < <(tmux list-panes -t "$WINDOW_ID" -F '#{pane_id}' 2>/dev/null)

[ -n "$icons" ] && printf ' %s' "$icons"
exit 0
