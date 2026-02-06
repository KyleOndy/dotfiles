#!/usr/bin/env bash
# Claude Code Statusline
# Displays: git branch | model | context usage | session cost | session duration

set -euo pipefail

# Read JSON input from stdin
input=$(cat)

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

# Extract context window usage percentage (truncate to integer)
context_pct=$(echo "$input" | jq -r '.context_window.used_percentage // 0 | floor')

# Extract context window size and format (200k or 1M)
context_size=$(echo "$input" | jq -r '.context_window.context_window_size // 0')
if [ "$context_size" != "0" ] && [ "$context_size" != "null" ]; then
	if [ "$context_size" -ge 1000000 ]; then
		context_size_formatted="$((context_size / 1000000))M"
	else
		context_size_formatted="$((context_size / 1000))k"
	fi
else
	context_size_formatted=""
fi

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

# Context window usage
if [ -n "$context_size_formatted" ] && [ "$context_pct" != "0" ]; then
	context_display="Ctx: ${context_pct}%/${context_size_formatted}"
	[ -n "$output" ] && output="$output | "
	output="${output}${context_display}"
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

echo "$output"
