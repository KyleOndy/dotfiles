#!/usr/bin/env bash
set -euo pipefail

# Aggregates the coding agents' per-pane state for one tmux window.
# Usage: tmux-agent-icons.sh <window_id>
# Called from the window status format via #().
#
# Two agents, two channels, because they publish from opposite sides of a
# sandbox boundary. Claude Code's hooks run unsandboxed and set a pane
# option (@claude_state, claude-code/hooks/tmux-indicator.sh). pi runs
# inside srt, which denies the tmux socket, so it fronts the terminal title
# with a `[pi:STATE]` token (pi/extensions/terminal-title.ts) and tmux
# records that as pane_title.

WINDOW_ID="${1:-}"
[ -n "$WINDOW_ID" ] || exit 0
command -v tmux >/dev/null 2>&1 || exit 0

icons=""

add() {
	icons="${icons:+${icons} }$1"
}

# One format call reads both channels: #{@name} resolves the listed pane's
# own user option, so no show-option fork per pane per status refresh.
while IFS='|' read -r claude_state pane_title; do
	[ -n "$claude_state" ] && add "cc:${claude_state}"
	case "$pane_title" in
	"[pi:"*"]"*)
		state=${pane_title#"[pi:"}
		add "pi:${state%%"]"*}"
		;;
	esac
done < <(tmux list-panes -t "$WINDOW_ID" -F '#{@claude_state}|#{pane_title}' 2>/dev/null)

[ -n "$icons" ] && printf ' %s' "$icons"
exit 0
