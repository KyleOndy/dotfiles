#!/usr/bin/env bash
set -Ee


readonly FOUNDRY_DIR=${FOUNDRY_DATA:-$XDG_DATA_HOME}
readonly FOUNDRY_LOG_DIR="${FOUNDRY_DIR}/logs"

print_usage() {
  cat << EOF
usage of $(basename "$0"):

    c|commit        open $EDITOR with commit template
    c|commit <msg>  write commit with message

    l|log           open todays log file
    l|log <date>  open log of specified date

    o|ops|adhoc     work on unplanned ticket

    w|work|workon   switch to ticket folder

    dir             print directory of foundry work directory
EOF
}

#######################################
# Creates if needed, and switches to a tmux window with the given name
# Arguments:
#   Name of the tmux window
#   Working directory to set in new window
#######################################
function create_and_switch_to_tmux_window() {
  local window_name="$1"
  local working_dir="$2"
  local window_information
  local tmux_args
  local window_id

  window_information=$(tmux list-windows -F "#I,#W" | \
    rg --regexp "[\d]+,${window_name}" || true)

  if [[ -z "${window_information}" ]]; then
    tmux_args=(
      new-window          # create new window
      -n "${window_name}" # named
      -P                  # print info about window to stdout
      -F "#I"             # print just window ID
      -d                  # don't switch to window
      -c "${working_dir}" # set working directory
    )

    # set working directory if passed
    [[ -z "${working_dir}" ]] && tmux_args+=( -c "${working_dir}")

    window_id=$(tmux "${tmux_args[@]}")
  else
    window_id="$(echo "${window_information}" | cut -d',' -f1)"
  fi
  tmux select-window -t "$window_id"
}

#######################################
# Creates the working directory and new tmux window for a given ticket
# If already created, switch to existing window
# Arguments:
#   Name of the tmux window
#   Working directory to set in new window
# TODO:
#   Add zsh competion for current tickets
#######################################
work_on() {
  if [[ -z $JIRA_ROOT ]]; then
    echo "Please set \$JIRA_ROOT"
    exit 1
  fi
  local ticket=${1^^}
  local project

  project="$(echo "$ticket" | cut -d'-' -f1)"
  pushd "$FOUNDRY_DIR"

  mkdir -p "./$project/$ticket"

  # todo: move these into templte files
  if ! [ -f "./$project/$ticket/README.md" ]; then
cat <<- EOF > "./$project/$ticket/README.md"
# $ticket

[Jira ticket for $ticket](${JIRA_ROOT}/browse/$ticket)

Readme generated on $(date).

EOF
    # strip the leading two spaces the `jira` cli still outputs even with the
    # `--plain` flag.
    ticket_content=$(jira issue view "${ticket}" --plain | sed -e 's/^  //'
)
    if [[ -n $ticket_content ]]; then
      echo "## Conents of ${ticket}" >> "./$project/$ticket/README.md"
      echo "${ticket_content}" >> "./$project/$ticket/README.md"
    fi
  fi
  if ! [ -f "./$project/$ticket/flake.nix" ]; then
cat <<- EOF > "./$project/$ticket/flake.nix"
{
  description = "$ticket";

  inputs.flake-utils.url = "github:numtide/flake-utils";

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem
      (system:
        let pkgs = nixpkgs.legacyPackages.\${system}; in
        {
          devShell = import ./shell.nix { inherit pkgs; };
        }
      );
}
EOF
  fi
  if ! [ -f "./$project/$ticket/shell.nix" ]; then
cat <<- EOF > "./$project/$ticket/shell.nix"
{ pkgs ? import <nixpkgs> { } }:
with pkgs;
mkShell {
  buildInputs = [
    # ...
  ];

  shellHook = ''
    # ...
  '';
}
EOF
  fi
  if ! [ -f "./$project/$ticket/.envrc" ]; then
cat <<- EOF > "./$project/$ticket/.envrc"
# this uses, and assumeds the nix-direnv [1] is configured in your enviroemnt
# [1]: https://github.com/nix-community/nix-direnv
use nix
EOF
  fi
  create_and_switch_to_tmux_window "${ticket}" "${FOUNDRY_DIR}/${project}/${ticket}"

  #SLACK_CLI_TOKEN="$(pass show paigeai.slack.com/user_token )" slack status edit "Working on $ticket" :hammer_and_wrench:
  #git checkout -b "$ticket" || git checkout "$ticket"
}

log() {
  local dte="$*"
  local date_format="+%Y-%m-%d"
  local date_string
  local log_file


  date_string=$(date "${date_format}" --date "${dte}")
  log_file="${FOUNDRY_LOG_DIR}/${date_string}.md"

  [[ -d "${FOUNDRY_LOG_DIR}" ]] || mkdir "${FOUNDRY_LOG_DIR}"

  if [[ ! -f "${log_file}" ]]; then
    # TODO: copy some template file
    echo "# ${date_string}" > "${log_file}"
  fi
  if [[ "${EDITOR}" == "nvim" ]]; then
    printf "\n\n" >> "${log_file}"
    nvim "${log_file}" -c "startinsert" +
  else
    $EDITOR "${log_file}"
  fi

}

print_dir() {
  # TODO: check some ENVVAR to see if we are in a work directory
  tmux display-message -p '#W'
}

## ENTRYPOINT
[[ -d "$FOUNDRY_DIR" ]] || mkdir -p "$FOUNDRY_DIR"


case "$1" in
  "")
    print_usage
    ;;
  "w"|"work"|"workon")
    shift

    # assuming ticket is the form of PROJ-###
    work_on "$@"
    #log "$@"
    ;;
  "l"|"log")
    shift
    log "$@"
    ;;
  "o"|"ops"|"adhoc")
    shift
    if [ -z "$1" ]; then
      t_stamp=$(date +%s)
      work_on "ADHOC-$t_stamp"
    else
      work_on "ADHOC-$1"
    fi
    ;;
  "c"|"commit")
    shift
    # todo: this makes so many assumptions
    git cmm "$(basename "$PWD"):" -e
    ;;
  "dir")
    print_dir
    ;;
  *)
    print_usage
    ;;
esac
