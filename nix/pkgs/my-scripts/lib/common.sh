#!/usr/bin/env bash
# Common library for shell scripts
# Source this file at the beginning of scripts to use shared functions
#
# Dependencies: bash/zsh, git, GNU date, ripgrep (rg)
# Designed for personal use on controlled systems

# Enable strict error handling
# Call this function at the start of scripts that want strict mode
set_strict_mode() {
    set -Eeuo pipefail
}

# Color constants for terminal output
# Colors are automatically disabled if stderr is not a TTY
# Supports NO_COLOR environment variable (https://no-color.org/)
#
# Note: Uses dynamic detection instead of readonly to work correctly
# in subshells and when stderr is redirected
#
# shellcheck disable=SC2034  # Variables exported for external use
if [[ -t 2 ]] && [[ "${NO_COLOR:-}" != "1" ]]; then
    # Stderr is a TTY and NO_COLOR is not set - enable colors
    # Using Gruvbox palette with 256-color ANSI codes
    COLOR_RED='\033[38;5;167m'    # Gruvbox bright red (#fb4934)
    COLOR_GREEN='\033[38;5;142m'  # Gruvbox bright green (#b8bb26)
    COLOR_YELLOW='\033[38;5;214m' # Gruvbox bright yellow (#fabd2f)
    COLOR_BLUE='\033[38;5;109m'   # Gruvbox blue (#83a598)
    COLOR_BOLD='\033[1m'
    COLOR_RESET='\033[0m'

    # Color blocks for visual indicators (like mori script)
    COLOR_BLOCK_RED="\033[48;5;167m \033[0m"   # Gruvbox red background
    COLOR_BLOCK_GREEN="\033[48;5;142m \033[0m" # Gruvbox green background
else
    # No colors when piped/redirected or NO_COLOR is set
    COLOR_RED=''
    COLOR_GREEN=''
    COLOR_YELLOW=''
    COLOR_BLUE=''
    COLOR_BOLD=''
    COLOR_RESET=''
    COLOR_BLOCK_RED=''
    COLOR_BLOCK_GREEN=''
fi

# Logging functions with consistent formatting
# All logs go to stderr and include ISO-8601 timestamp
# Format: [timestamp] [LEVEL] message
#
# Levels are whitespace-aligned for clean output:
#   [INFO ]
#   [WARN ]
#   [ERROR]
#   [DEBUG]

# Print an info message
# Usage: log_info "Operation completed successfully"
log_info() {
    echo -e "[$(date --iso-8601=seconds)] ${COLOR_GREEN}[INFO ]${COLOR_RESET} $*" >&2
}

# Print a warning message
# Usage: log_warn "This operation may take a while"
log_warn() {
    echo -e "[$(date --iso-8601=seconds)] ${COLOR_YELLOW}[WARN ]${COLOR_RESET} $*" >&2
}

# Print an error message
# Usage: log_error "Operation failed"
log_error() {
    echo -e "[$(date --iso-8601=seconds)] ${COLOR_RED}[ERROR]${COLOR_RESET} $*" >&2
}

# Print a debug message (only if DEBUG env var is set)
# Usage: DEBUG=1 ./script.sh
log_debug() {
    [[ -n "${DEBUG:-}" ]] &&
        echo -e "[$(date --iso-8601=seconds)] ${COLOR_BLUE}[DEBUG]${COLOR_RESET} $*" >&2
    return 0
}

# Print a message with yellow highlight (used for prompts/interactive messages)
# Note: This goes to stdout (not stderr) since it's for interactive prompts
# Usage: log_highlight "Select worktrees to remove..."
log_highlight() {
    echo -e "${COLOR_YELLOW}$*${COLOR_RESET}"
}

# Error handling

# Print error message and exit with status code
# Usage: die "Configuration file not found"
# Usage: die "Invalid input" 2
die() {
    local message="$1"
    local exit_code="${2:-1}"
    log_error "$message"
    exit "$exit_code"
}

# Git worktree utilities

# Get the root directory of the worktree-based repository
# Returns the parent directory containing .bare and .git
# Returns empty string if not in a worktree-based repo
# Note: Requires ripgrep (rg) for fast regex matching
# Usage: wt_root=$(get_worktree_root)
get_worktree_root() {
    git worktree list --porcelain 2>/dev/null |
        rg '^worktree.*\.bare$' |
        sed 's/\/\.bare$//' |
        sort -u |
        cut -d' ' -f2 || true
}

# Require that we're in a worktree-based repository
# Exits with error if not in a worktree repo
# Usage: require_worktree_repo
require_worktree_repo() {
    local wt_root
    wt_root=$(get_worktree_root)

    if [[ -z "$wt_root" ]]; then
        die "Not in a worktree-based repository (no .bare found)
To set up a repository for this workflow, use: git wt-clone <url>"
    fi

    echo "$wt_root"
}

# Detect the default branch for the remote repository
# Tries multiple methods in order of reliability:
# 1. Git's symbolic-ref (official default branch tracking)
# 2. Check if origin/main exists
# 3. Check if origin/master exists
# 4. Fall back to origin/main
# Usage: default_branch=$(get_default_branch)
get_default_branch() {
    # Try symbolic-ref first (most reliable)
    if default_branch=$(git symbolic-ref refs/remotes/origin/HEAD --short 2>/dev/null); then
        echo "$default_branch"
        return 0
    fi

    # Fallback: try main first, then master
    if git show-ref --verify --quiet refs/remotes/origin/main; then
        echo "origin/main"
        return 0
    fi

    if git show-ref --verify --quiet refs/remotes/origin/master; then
        echo "origin/master"
        return 0
    fi

    # Last resort: just use main (will fail later if it doesn't exist)
    echo "origin/main"
}

# Detect the default branch for a remote repository URL
# Useful when cloning a new repository
# Usage: default_branch=$(get_default_branch_from_url "https://github.com/user/repo")
get_default_branch_from_url() {
    local repo_url=$1
    local head_commit
    local branches_on_head
    local branch_count
    local default_branch

    head_commit=$(git ls-remote "$repo_url" HEAD | cut -f1 | head -n1)
    branches_on_head=$(git ls-remote "$repo_url" | rg --fixed-strings "$head_commit" | rg 'refs/heads/' | cut -f2 | cut -d'/' -f3-)

    # Check if empty first to avoid wc -l off-by-one bug with here-strings
    if [[ -z "$branches_on_head" ]]; then
        die "Can't determine default branch for $repo_url"
    fi

    branch_count=$(wc -l <<<"$branches_on_head")

    default_branch="main"
    if [[ $branch_count -eq 1 ]]; then
        default_branch="$branches_on_head"
    else
        if echo "$branches_on_head" | grep -q "main"; then
            default_branch="main"
        elif echo "$branches_on_head" | grep -q "master"; then
            default_branch="master"
        else
            # Use first branch found
            default_branch=$(head -n1 <<<"$branches_on_head")
        fi
    fi

    echo "$default_branch"
}

# Utility functions

# Convert seconds to human-readable format
# Handles edge cases: 0 seconds, very small times, and multi-day durations
# Usage: human_time=$(seconds_to_human 9000)
# Examples:
#   seconds_to_human 0      -> "0s"
#   seconds_to_human 30     -> "30s"
#   seconds_to_human 90     -> "1m 30s"
#   seconds_to_human 3661   -> "1h 1m 1s"
#   seconds_to_human 90000  -> "1d 1h 0m"
seconds_to_human() {
    local seconds=$1
    local days=$((seconds / 86400))
    local hours=$(((seconds % 86400) / 3600))
    local minutes=$(((seconds % 3600) / 60))
    local secs=$((seconds % 60))

    local result=""

    # Build output string for non-zero components
    [[ $days -gt 0 ]] && result="${days}d "
    [[ $hours -gt 0 ]] && result="${result}${hours}h "
    [[ $minutes -gt 0 ]] && result="${result}${minutes}m "

    # Always show seconds if:
    # 1. No larger units (e.g., "30s" for 30 seconds)
    # 2. Seconds are non-zero (e.g., "1m 30s" not just "1m")
    if [[ -z "$result" ]] || [[ $secs -gt 0 ]]; then
        result="${result}${secs}s"
    fi

    # Trim trailing space and output
    echo "${result% }"
}

# Check if a command exists
# Usage: if command_exists fzf; then ... fi
command_exists() {
    command -v "$1" &>/dev/null
}

# Require that a command exists, exit with error if not
# Usage: require_command fzf "Install fzf to use interactive mode"
require_command() {
    local cmd=$1
    local message="${2:-Command \"$cmd\" is required but not found}"

    if ! command_exists "$cmd"; then
        die "$message"
    fi
}

# Confirm an action with the user (y/N prompt)
# Returns 0 if user confirmed, 1 otherwise
# Usage: if confirm "Delete these files?"; then ... fi
confirm() {
    local prompt="$1"
    local default="${2:-N}"
    local reply

    if [[ "$default" == "Y" ]]; then
        read -p "$prompt [Y/n] " -n 1 -r reply
    else
        read -p "$prompt [y/N] " -n 1 -r reply
    fi
    echo

    if [[ -z "$reply" ]]; then
        reply="$default"
    fi

    [[ "$reply" =~ ^[Yy]$ ]]
}

# Show a help message and exit
# Usage: show_help "usage: $0 [options]" "Description of the script" ...
show_help() {
    for line in "$@"; do
        echo "$line"
    done
    exit 0
}

# Validation functions

# Validate Jira ticket format (PROJ-123)
# Usage: if is_valid_jira_ticket "DEV-123"; then ... fi
is_valid_jira_ticket() {
    local ticket=$1
    [[ "$ticket" =~ ^[A-Z]+-[0-9]+$ ]]
}

# Validate that a directory exists
# Usage: validate_directory "/path/to/dir" "Config directory"
validate_directory() {
    local dir=$1
    local description="${2:-Directory}"

    if [[ ! -d "$dir" ]]; then
        die "$description does not exist: $dir"
    fi
}

# Validate that a file exists
# Usage: validate_file "/path/to/file" "Config file"
validate_file() {
    local file=$1
    local description="${2:-File}"

    if [[ ! -f "$file" ]]; then
        die "$description does not exist: $file"
    fi
}
