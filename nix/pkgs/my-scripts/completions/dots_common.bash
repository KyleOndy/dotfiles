#!/usr/bin/env bash

# These are functions that are used in more than one completion function. Moved
# here for reuse.

_debug() {
	[[ -n ${DEBUG} ]] && >&2 echo "DEBUG: $(date --iso-8601=seconds): $*"
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

_linear_tickets() {
	# Only available in work context
	if ! is_work_context; then
		_debug "not in work context, skipping linear"
		return 0
	fi

	# the format here is described in the zsh completion man page
	# each item needs to have the following format
	#     PROJ-1234\:'[Foo]: do things'
	#     PROJ-2345\:'foobar'
	# TODO: do I need to escape the summary field for single quote (') characters?

	# linear-cli outputs a table with ANSI colors, columns: priority, ID, title, labels, estimate, state, updated
	# We need to: strip ANSI codes, skip header, extract ID and title
	linear issue list -s started -s unstarted --sort priority --no-pager 2>/dev/null |
		sed -r "s/\x1B\[([0-9]{1,3}(;[0-9]{1,2})?)?[mGK]//g" |
		tail -n +2 |
		gawk '{
      # Extract ID (pattern: [A-Z]+-[0-9]+)
      match($0, /[A-Z]+-[0-9]+/, id);
      # Extract everything after the ID as the title (until labels column which starts with emoji or whitespace)
      match($0, /[A-Z]+-[0-9]+[[:space:]]+(.+?)[[:space:]]{2,}/, arr);
      if (id[0] != "" && arr[1] != "") {
        # Remove trailing whitespace from title
        gsub(/[[:space:]]+$/, "", arr[1]);
        printf "%s\\:\047%s\047\n", id[0], arr[1];
      }
    }'
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
