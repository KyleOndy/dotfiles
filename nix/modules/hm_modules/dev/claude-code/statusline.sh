#!/usr/bin/env bash
# Claude Code Statusline
# Displays: git branch | model (effort) | context | rate limits | cost | duration | lines
#
# Runs on every render (debounced ~300ms), so it prefers bash builtins over
# forks: printf '%(...)T' replaces date(1) and git is called at most once.

set -euo pipefail

# Read JSON from stdin.
input=$(cat)

# Extract every field in one jq pass, joined on the unit separator (0x1f). A
# non-whitespace delimiter keeps empty fields (e.g. an absent effort) in place;
# read with IFS=tab collapses runs of tabs and would shift model off the end.
IFS=$'\037' read -r cwd cost_usd duration_ms lines_added lines_removed \
	context_size context_used_tokens context_pct \
	rl_5h rl_7d rl_5h_resets rl_7d_resets effort model < <(
		echo "$input" | jq -r '[
		(.cwd // .workspace.current_dir // ""),
		(.cost.total_cost_usd // 0),
		(.cost.total_duration_ms // 0),
		(.cost.total_lines_added // 0),
		(.cost.total_lines_removed // 0),
		(.context_window.context_window_size // 0),
		((.context_window.used_percentage // 0) / 100 * (.context_window.context_window_size // 0) | floor),
		(.context_window.used_percentage // 0 | floor),
		(.rate_limits.five_hour.used_percentage // 0 | floor),
		(.rate_limits.seven_day.used_percentage // 0 | floor),
		(.rate_limits.five_hour.resets_at // 0 | floor),
		(.rate_limits.seven_day.resets_at // 0 | floor),
		(.effort.level // ""),
		(.model.display_name // "")
	] | map(tostring) | join("")' 2>/dev/null
	) || exit 0 # render nothing on empty or malformed input

# Git branch: one call; empty outside a repo. Fall back to short SHA on detached HEAD.
branch=$(git -C "$cwd" branch --show-current 2>/dev/null || true)
[ -z "$branch" ] && branch=$(git -C "$cwd" rev-parse --short HEAD 2>/dev/null || true)

# Session duration (roll over to hours for long sessions).
if [ "$duration_ms" != "0" ]; then
	total_seconds=$((duration_ms / 1000))
	hours=$((total_seconds / 3600))
	minutes=$(((total_seconds % 3600) / 60))
	seconds=$((total_seconds % 60))
	if [ "$hours" -gt 0 ]; then
		duration="${hours}h ${minutes}m"
	else
		duration="${minutes}m ${seconds}s"
	fi
else
	duration=""
fi

# Context window usage.
if [ "$context_size" != "0" ]; then
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

# Rate limit reset time: clock time (e.g. "2:30p") or relative hours (e.g. "26h").
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
		printf -v time_str '%(%-I:%M%P)T' "$resets_at"
		# Strip trailing 'm' from am/pm: 'am' -> 'a', 'pm' -> 'p'.
		echo "(${time_str%m})"
	fi
}

printf -v now '%(%s)T' -1

# ANSI colors (honor NO_COLOR: https://no-color.org/).
if [ -n "${NO_COLOR:-}" ]; then
	c_reset='' c_dim='' c_branch='' c_model='' c_ok='' c_warn='' c_hot=''
else
	c_reset=$'\e[0m'
	c_dim=$'\e[2m'
	c_branch=$'\e[36m'
	c_model=$'\e[1m'
	c_ok=$'\e[32m'
	c_warn=$'\e[33m'
	c_hot=$'\e[31m'
fi

# Pick a fullness color for a percentage into $_pc (no subshell).
pct_color() {
	if [ "$1" -ge 90 ]; then
		_pc=$c_hot
	elif [ "$1" -ge 70 ]; then
		_pc=$c_warn
	else
		_pc=$c_ok
	fi
}

# Append a segment, inserting a dim separator when output is non-empty.
output=""
add() {
	[ -n "$output" ] && output="${output} ${c_dim}|${c_reset} "
	output="${output}$1"
}

# Git branch.
[ -n "$branch" ] && add "${c_branch}⎇ ${branch}${c_reset}"

# Model name and reasoning effort.
if [ -n "$model" ]; then
	seg="${c_model}${model}${c_reset}"
	[ -n "$effort" ] && seg="${seg} ${c_dim}(${effort})${c_reset}"
	add "$seg"
fi

# Context window usage, colored by fullness.
if [ -n "$context_size_formatted" ] && [ "$context_used_tokens" != "0" ]; then
	pct_color "$context_pct"
	add "Ctx: ${_pc}${context_used_formatted}/${context_size_formatted}${c_reset}"
fi

# Rate limit usage with reset times, colored by fullness.
if [ "$rl_5h" != "0" ] || [ "$rl_7d" != "0" ]; then
	rl_5h_reset_str=$(format_reset_time "$rl_5h_resets" "$now")
	rl_7d_reset_str=$(format_reset_time "$rl_7d_resets" "$now")
	pct_color "$rl_5h"
	c5=$_pc
	pct_color "$rl_7d"
	c7=$_pc
	add "RL: ${c5}${rl_5h}%/5h${c_reset}${rl_5h_reset_str} ${c7}${rl_7d}%/7d${c_reset}${rl_7d_reset_str}"
fi

# Session cost.
if [ "$cost_usd" != "0" ] && [ "$cost_usd" != "null" ]; then
	printf -v cost_formatted '$%.4f' "$cost_usd"
	add "${c_dim}${cost_formatted}${c_reset}"
fi

# Session duration.
[ -n "$duration" ] && add "${c_dim}${duration}${c_reset}"

# Lines added/removed.
if [ "$lines_added" != "0" ] || [ "$lines_removed" != "0" ]; then
	add "${c_ok}+${lines_added}${c_reset}${c_dim}/${c_reset}${c_hot}-${lines_removed}${c_reset}"
fi

echo "$output"
