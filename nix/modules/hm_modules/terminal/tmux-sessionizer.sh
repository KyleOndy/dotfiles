#!/usr/bin/env bash
set -euo pipefail

# Switches to the tmux session for a worktree, making it first if needed.
# Usage: tmux-sessionizer [path]
# With no path, picks an existing session or a worktree under ~/src in fzf.
#
# A worktree in a ticket directory ({repo}/DEV-123/<name>, git
# wt-feature-branch's work mode) joins session DEV-123 as a window of its own,
# so every repo and pi agent on a ticket shares one session. Any other
# worktree gets session <repo>/<name>.

readonly SRC_DIR="${HOME}/src"
readonly SESSION_TAG="session: "

pick() {
	{
		tmux list-sessions -F "${SESSION_TAG}#S" 2>/dev/null || true
		fd --hidden --no-ignore --max-depth 5 --exclude .bare --exclude node_modules \
			--format '{//}' '^\.git$' "${SRC_DIR}" |
			while read -r dir; do
				# A bare repo's root holds .bare and a .git file pointing at it,
				# and is no checkout.
				[[ -d ${dir}/.bare ]] || echo "${dir#"${SRC_DIR}"/}"
			done | sort
	} | fzf --reverse --prompt 'session> '
}

target="${1:-}"
if [[ -z ${target} ]]; then
	# Escape in fzf is a choice not to switch, not an error.
	target="$(pick)" || exit 0
fi

if [[ ${target} == "${SESSION_TAG}"* ]]; then
	session="${target#"${SESSION_TAG}"}"
else
	[[ ${target} == /* ]] || target="${SRC_DIR}/${target}"
	# Physical, because that is what tmux reports as pane_current_path.
	path="$(cd "${target}" && pwd -P)"
	name="${path##*/}"
	parent="$(basename "$(dirname "${path}")")"
	if [[ ${parent} =~ ^[A-Z]+-[0-9]+$ ]]; then
		session="${parent}"
	else
		session="${parent}/${name}"
	fi
	# tmux rewrites both in a session name, which would break the exact match.
	session="${session//[.:]/_}"

	if ! tmux has-session -t "=${session}" 2>/dev/null; then
		tmux new-session -d -s "${session}" -n "${name}" -c "${path}"
	elif ! tmux list-panes -s -t "=${session}" -F '#{pane_current_path}' | grep -qxF "${path}"; then
		tmux new-window -t "=${session}:" -n "${name}" -c "${path}"
	fi
fi

if [[ -n ${TMUX:-} ]]; then
	tmux switch-client -t "=${session}"
else
	tmux attach-session -t "=${session}"
fi
