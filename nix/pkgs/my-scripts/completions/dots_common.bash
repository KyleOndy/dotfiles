#!/usr/bin/env bash

# These are functions that are used in more than one compeltion function.

jira_cache_valid_seconds="60s"

_jira_tickets() {
  # the format here is descibed in the zsh compeltion man page
  # each item needs to have the following format
  #     PLAT-1234\:'[Foo]: do things'
  #     PLAT-2345\:'foobar'
  # TODO: do I need to escape the summary for ' chracters?
  jira issue list -a"$(jira me)" -s~Done --jql 'sprint in openSprints ()' --plain --no-headers --columns key,summary | \
    sed -E "s|\t|\\\:'|" | \
    sed -E "s|$|'|"
}


_jira_tickets_cached() {
  cache_root="${XDG_CACHE_HOME:-$HOME/.cache}"
  cache_dir="${cache_root}/dots/"
  cache_file="in-progress-jira-tickets"

  [[ -d "${cache_dir}" ]] || mkdir -p "${cache_dir}"

  # ASSUME: only one file returned
  cached_file=$(fd --absolute-path --changed-within="${jira_cache_valid_seconds}" "${cache_file}" "${cache_dir}")
  if [[ -z "$cached_file" ]]; then
    _jira_tickets | tee "${cache_dir}/${cache_file}"
  else
    cat "$cached_file"
  fi
}
