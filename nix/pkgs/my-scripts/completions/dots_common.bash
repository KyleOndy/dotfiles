#!/usr/bin/env bash

# These are functions that are used in more than one completion function. Moved
# here for reuse.

_debug() {
	[[ -n ${DEBUG} ]] && >&2 echo "DEBUG: $(date -Iseconds): $*"
}

# ============================================================================
# Context Detection
# ============================================================================
#
# Use DOTS_CONTEXT environment variable to detect work vs home environment.
# This allows scripts to adapt behavior based on context.
#
# Set in home-manager per-host config:
#   home.sessionVariables.DOTS_CONTEXT = "work";  # Work machines
#   home.sessionVariables.DOTS_CONTEXT = "home";  # Home machines (or unset)
#
# Defaults to "home" if unset.
#
# Examples:
#   if is_work_context; then
#     # Enable corporate features (Linear, VPN-dependent tools, etc.)
#   fi
#
#   if is_home_context; then
#     # Personal workflow
#   fi

is_work_context() {
	[[ ${DOTS_CONTEXT} == "work" ]]
}

is_home_context() {
	[[ ${DOTS_CONTEXT:-home} == "home" ]]
}

get_context() {
	echo "${DOTS_CONTEXT:-home}"
}

# ============================================================================
# Linear Integration
# ============================================================================

linear_cache_valid_seconds=${LINEAR_CACHE_VALID_SECONDS:-60}

# Emit "ID<TAB>state<TAB>title" lines for every ticket assigned to the
# authenticated user across any team that is either still open or was
# completed within the last 24 hours. Sort order: started → backlog/unstarted
# → triage → done; then priority (urgent first, no-priority last); then
# oldest first. Priority is used for sorting but not displayed. Titles are
# clamped to WORK_COMPLETION_TITLE_MAX (default 60) chars with an ellipsis.
# Requires LINEAR_API_KEY in env.
_linear_tickets() {
	if ! is_work_context; then
		_debug "not in work context, skipping linear"
		return 0
	fi

	if [[ -z ${LINEAR_API_KEY:-} ]]; then
		_debug "LINEAR_API_KEY not set, skipping linear"
		return 0
	fi

	local cutoff
	cutoff=$(date -u -v-1d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ||
		date -u -d '1 day ago' +%Y-%m-%dT%H:%M:%SZ)

	local payload
	payload=$(jq -n --arg cutoff "$cutoff" '
		{
			query: "query { issues(first: 100, filter: { assignee: { isMe: { eq: true } }, or: [ { state: { type: { nin: [\"completed\",\"canceled\"] } } }, { completedAt: { gte: \"\($cutoff)\" } } ] }) { nodes { identifier title priority createdAt state { type name } } } }"
		}
	')

	local max=${WORK_COMPLETION_TITLE_MAX:-60}

	curl -sS --max-time 5 -X POST https://api.linear.app/graphql \
		-H "Authorization: ${LINEAR_API_KEY}" \
		-H "Content-Type: application/json" \
		--data "${payload}" 2>/dev/null |
		jq -r --argjson max "$max" '
			def state_rank:
				if . == "started" then 0
				elif . == "backlog" or . == "unstarted" then 1
				elif . == "triage" then 2
				else 3 end;
			def prio_rank:
				# Linear: 0=none, 1=urgent, 2=high, 3=normal, 4=low. Put none last.
				if (. // 0) == 0 then 5 else . end;
			(.data.issues.nodes // [])
			| sort_by([(.state.type | state_rank), (.priority | prio_rank), .createdAt])
			| .[]
			| . as $i
			| (if ($i.title | length) > $max then ($i.title[0:($max - 1)] + "…") else $i.title end) as $t
			| "\($i.identifier)\t\($i.state.name)\t\($t)"
		' 2>/dev/null
}

_linear_tickets_cached() {
	# Only available in work context
	if ! is_work_context; then
		_debug "not in work context, no linear cache"
		return 0
	fi

	cache_root="${XDG_CACHE_HOME:-$HOME/.cache}"
	cache_dir="${cache_root}/dots/"
	cache_file="in-progress-linear-tickets"
	cache_file_path="${cache_dir}/${cache_file}"

	[[ -d ${cache_dir} ]] || mkdir -p "${cache_dir}"

	# Check if cache file exists before calculating age
	if [[ -f ${cache_file_path} ]]; then
		cache_age=$(($(date +%s) - $(date +%s --reference "${cache_file_path}")))
		_debug "cache age: $cache_age"
	else
		# Force cache refresh on first run
		cache_age=$((linear_cache_valid_seconds + 1))
		_debug "cache file does not exist, forcing refresh"
	fi

	if [[ ${cache_age} -gt ${linear_cache_valid_seconds} ]]; then
		_debug "cache miss: writing to cache"
		_linear_tickets >"${cache_file_path}"
	fi

	_debug "returning from cache"
	cat "${cache_file_path}"
}

# ============================================================================
# Title sanitization
# ============================================================================

# Strip control chars, collapse whitespace, and cap to WORK_COMPLETION_TITLE_MAX chars.
_work_sanitize() {
	local s=$1
	s=${s//$'\r'/ }
	s=${s//$'\n'/ }
	s=${s//$'\t'/ }
	s=$(printf '%s' "$s" | tr -s '[:space:]' ' ')
	s=${s#"${s%%[![:space:]]*}"}
	s=${s%"${s##*[![:space:]]}"}
	local max=${WORK_COMPLETION_TITLE_MAX:-60}
	if ((${#s} > max)); then
		s="${s:0:$((max - 1))}…"
	fi
	printf '%s' "$s"
}

# ============================================================================
# Work ticket completion (Linear in-progress tickets)
# ============================================================================
#
# Emits one "ID<TAB>state<TAB>title" line per in-progress Linear ticket,
# 60s cached. Local ticket dirs are intentionally excluded.

# Outputs one tab-separated "ID<TAB>state<TAB>title" line per ticket.
_work_tickets_cached() {
	# Declare all locals once at function scope. Re-declaring `local` inside
	# loops in zsh (which sources this file) causes `local name` to dump the
	# existing value unless TYPESET_SILENT is set — that bled literal
	# `desc='...'` lines into the stream.
	local linear_output lid lstate ltitle

	linear_output=$(_linear_tickets_cached)
	[[ -z $linear_output ]] && return 0

	while IFS=$'\t' read -r lid lstate ltitle; do
		[[ -z $lid ]] && continue
		printf '%s\t%s\t%s\n' "$lid" "$lstate" "$(_work_sanitize "$ltitle")"
	done <<<"$linear_output"
}

# Zsh completion helper: one line per ticket showing "ID  [state]  title"
# with ID and [state] padded to max widths so titles align.
# compadd -l forces single-column list; -V preserves the upstream sort order
# (default compadd re-sorts alphabetically); -d supplies the display strings
# while -a supplies the actual values inserted (bare IDs).
_work_describe_tickets() {
	local -a values displays rows
	local id state title line bracketed
	local -i max_id=0 max_state=0

	# First pass: buffer rows and measure column widths.
	while IFS=$'\t' read -r id state title; do
		[[ -z $id ]] && continue
		bracketed="[${state}]"
		((${#id} > max_id)) && max_id=${#id}
		((${#bracketed} > max_state)) && max_state=${#bracketed}
		rows+=("${id}"$'\t'"${state}"$'\t'"${title}")
	done < <(_work_tickets_cached)

	# Second pass: pad to uniform columns.
	for line in "${rows[@]}"; do
		IFS=$'\t' read -r id state title <<<"$line"
		values+=("$id")
		displays+=("$(printf '%-*s  %-*s  %s' "$max_id" "$id" "$max_state" "[${state}]" "$title")")
	done

	compadd -l -V work-tickets -d displays -a values
}
