#!/usr/bin/env bash
# Claude Code Statusline
# Displays: git branch | model | session cost | session duration

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
