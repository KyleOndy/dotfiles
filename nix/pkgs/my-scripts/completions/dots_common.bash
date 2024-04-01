#!/usr/bin/env bash

# These are functions that are used in more than one completion function. Moved
# here for reuse.

_debug() {
  [[ -n "${DEBUG}" ]] && >&2 echo "DEBUG: $(date --iso-8601=seconds): $*"
}

jira_cache_valid_seconds=${JIRA_CACHE_VALID_SECONDS:-60}

_jira_tickets() {
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
  cache_root="${XDG_CACHE_HOME:-$HOME/.cache}"
  cache_dir="${cache_root}/dots/"
  cache_file="in-progress-jira-tickets"
  cache_file_path="${cache_dir}/${cache_file}"

  [[ -d "${cache_dir}" ]] || mkdir -p "${cache_dir}"

  cache_age=$(( $(date +%s) - $(date +%s --reference "${cache_file_path}") ))
  _debug "cache age: $cache_age"
  if [[ "${cache_age}" -gt "${jira_cache_valid_seconds}" ]]; then
    _debug "cache miss: writing to cache"
    _jira_tickets > "${cache_file}"
  fi

  _debug "returning from cache"
  cat "$cache_file"
}
