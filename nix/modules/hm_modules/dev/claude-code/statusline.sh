#!/usr/bin/env bash
# Claude Code Statusline
# Displays: git branch | model | context usage | session cost | session duration

set -euo pipefail

# Read JSON input from stdin
input=$(tee /tmp/statusline-debug.json)

# Extract current working directory
cwd=$(echo "$input" | jq -r '.cwd // .workspace.current_dir')

# Get git branch (if in a git repo)
branch=""
if [ -d "$cwd/.git" ] || git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1; then
	branch=$(git -C "$cwd" branch --show-current 2>/dev/null || echo "")
fi

# Extract model display name
model=$(echo "$input" | jq -r '.model.display_name // ""')

# Extract session cost
cost_usd=$(echo "$input" | jq -r '.cost.total_cost_usd // 0')

# Extract session duration and format it
duration_ms=$(echo "$input" | jq -r '.cost.total_duration_ms // 0')
if [ "$duration_ms" != "0" ] && [ "$duration_ms" != "null" ]; then
	total_seconds=$((duration_ms / 1000))
	minutes=$((total_seconds / 60))
	seconds=$((total_seconds % 60))
	duration="${minutes}m ${seconds}s"
else
	duration=""
fi

# Extract lines added/removed
lines_added=$(echo "$input" | jq -r '.cost.total_lines_added // 0')
lines_removed=$(echo "$input" | jq -r '.cost.total_lines_removed // 0')

# Extract context window size and compute used tokens
context_size=$(echo "$input" | jq -r '.context_window.context_window_size // 0')
context_used_tokens=$(echo "$input" | jq -r '(.context_window.used_percentage // 0) / 100 * (.context_window.context_window_size // 0) | floor')
if [ "$context_size" != "0" ] && [ "$context_size" != "null" ]; then
	if [ "$context_size" -ge 1000000 ]; then
		context_size_formatted="$((context_size / 1000000))M"
	else
		context_size_formatted="$((context_size / 1000))k"
	fi
	if [ "$context_used_tokens" -ge 1000000 ]; then
		context_used_formatted="$((context_used_tokens / 1000000))M"
	else
		context_used_formatted="$((context_used_tokens / 1000))k"
	fi
else
	context_size_formatted=""
	context_used_formatted=""
fi

# Format rate limit reset time: local time (e.g. "2:30p") or relative hours (e.g. "26h")
format_reset_time() {
	local resets_at=$1
	local now=$2
	if [ "$resets_at" -le 0 ]; then
		echo ""
		return
	fi
	local diff=$((resets_at - now))
	if [ "$diff" -le 0 ]; then
		echo ""
		return
	fi
	if [ "$diff" -gt 86400 ]; then
		echo "($((diff / 3600))h)"
	else
		local time_str
		time_str=$(date -d "@$resets_at" '+%-I:%M%P')
		# Strip trailing 'm' from am/pm: 'am' -> 'a', 'pm' -> 'p'
		echo "(${time_str%m})"
	fi
}

# Extract rate limit data
now=$(date +%s)
rl_5h=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // 0 | floor')
rl_7d=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // 0 | floor')
rl_5h_resets=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // 0 | floor')
rl_7d_resets=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // 0 | floor')

# Build output
output=""

# Git branch
if [ -n "$branch" ]; then
	output="⎇ $branch"
fi

# Model name
if [ -n "$model" ]; then
	[ -n "$output" ] && output="$output | "
	output="${output}${model}"
fi

# Context window usage (raw tokens / total)
if [ -n "$context_size_formatted" ] && [ "$context_used_tokens" != "0" ]; then
	[ -n "$output" ] && output="$output | "
	output="${output}Ctx: ${context_used_formatted}/${context_size_formatted}"
fi

# Rate limit usage with reset times
if [ "$rl_5h" != "0" ] || [ "$rl_7d" != "0" ]; then
	rl_5h_reset_str=$(format_reset_time "$rl_5h_resets" "$now")
	rl_7d_reset_str=$(format_reset_time "$rl_7d_resets" "$now")
	[ -n "$output" ] && output="$output | "
	output="${output}RL: ${rl_5h}%/5h${rl_5h_reset_str} ${rl_7d}%/7d${rl_7d_reset_str}"
fi

# Session cost
if [ "$cost_usd" != "0" ] && [ "$cost_usd" != "null" ]; then
	cost_formatted=$(printf '$%.4f' "$cost_usd")
	[ -n "$output" ] && output="$output | "
	output="${output}${cost_formatted}"
fi

# Session duration
if [ -n "$duration" ]; then
	[ -n "$output" ] && output="$output | "
	output="${output}${duration}"
fi

# Lines added/removed
if [ "$lines_added" != "0" ] || [ "$lines_removed" != "0" ]; then
	[ -n "$output" ] && output="$output | "
	output="${output}+${lines_added}/-${lines_removed}"
fi

echo "$output"
