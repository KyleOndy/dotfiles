#!/usr/bin/env bash

# These are functions that are used in more than one completion function. Moved
# here for reuse.

_debug() {
  [[ -n "${DEBUG}" ]] && >&2 echo "DEBUG: $(date --iso-8601=seconds): $*"
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
#     # Enable corporate features (Jira, VPN-dependent tools, etc.)
#   fi
#
#   if is_home_context; then
#     # Personal workflow
#   fi

is_work_context() {
  [[ "${DOTS_CONTEXT}" == "work" ]]
}

is_home_context() {
  [[ "${DOTS_CONTEXT:-home}" == "home" ]]
}

get_context() {
  echo "${DOTS_CONTEXT:-home}"
}

# ============================================================================
# Jira Integration
# ============================================================================

jira_cache_valid_seconds=${JIRA_CACHE_VALID_SECONDS:-60}

_jira_tickets() {
  # Only available in work context
  if ! is_work_context; then
    _debug "not in work context, skipping jira"
    return 0
  fi

  # the format here is described in the zsh completion man page
  # each item needs to have the following format
  #     PROJ-1234\:'[Foo]: do things'
  #     PROJ-2345\:'foobar'
  # TODO: do I need to escape the summary field for single quote (') characters?
  # TODO: only returns tickets assigned to project.key in ~/.config/.jira/.config.yml
  jira issue list -a"$(jira me)" -s~Done -s~Closed --jql 'sprint in openSprints ()' --plain --no-headers --columns key,summary | \
    sed -E "s|\t|\\\:'|" | \
    sed -E "s|$|'|"
}


_jira_tickets_cached() {
  # Only available in work context
  if ! is_work_context; then
    _debug "not in work context, no jira cache"
    return 0
  fi

  cache_root="${XDG_CACHE_HOME:-$HOME/.cache}"
  cache_dir="${cache_root}/dots/"
  cache_file="in-progress-jira-tickets"
  cache_file_path="${cache_dir}/${cache_file}"

  [[ -d "${cache_dir}" ]] || mkdir -p "${cache_dir}"

  # Check if cache file exists before calculating age
  if [[ -f "${cache_file_path}" ]]; then
    cache_age=$(( $(date +%s) - $(date +%s --reference "${cache_file_path}") ))
    _debug "cache age: $cache_age"
  else
    # Force cache refresh on first run
    cache_age=$((jira_cache_valid_seconds + 1))
    _debug "cache file does not exist, forcing refresh"
  fi

  if [[ "${cache_age}" -gt "${jira_cache_valid_seconds}" ]]; then
    _debug "cache miss: writing to cache"
    _jira_tickets > "${cache_file_path}"
  fi

  _debug "returning from cache"
  cat "${cache_file_path}"
}
