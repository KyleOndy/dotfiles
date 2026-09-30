# shellcheck shell=bash
# writeShellApplication provides the shebang and `set -euo pipefail`; this
# file is only the body (nix/pkgs/pi-delegate/default.nix).
#
# pi-delegate -- hand one well-defined job to a headless pi run
#
# Usage: pi-delegate [--edit] [--tmux] [--name <name>] [--base <ref>] [--] <brief | ->
#        pi-delegate follow <name>
#
# Built for another agent (Claude Code) to call and follow: stdout is one line
# per tool the run calls, then its final message, and the exit status is pi's.
# Read-only by default, in the current directory. --edit gives it bash, edit
# and write, and always in a new worktree and branch named <name> off <base>,
# so the caller's checkout is never touched. --tmux, or PI_DELEGATE_TMUX=1,
# also shows the run in a tmux window; without it the run is headless. Either
# way the run outlives its caller, and `follow` picks it back up.
#
# Each run leaves <state>/<name>/ behind:
#   task.md          the brief
#   events.ndjson    pi's --mode json stream, the full record
#   stderr.log       pi's stderr
#   result.md        the final assistant message
#   workdir, base    where it ran, and the ref an --edit branch started from
#   exit             pi's exit status, written last; 124 when it timed out

readonly MODEL="${PI_DELEGATE_MODEL:-mcloud/zai-org/glm-5.3}"
readonly READ_TOOLS="read,grep,find,ls"
readonly EDIT_TOOLS="read,grep,find,ls,edit,write,bash"
# Wall clock for one run. A model can stall mid-stream or loop inside a tool
# call and never end its turn.
readonly TIMEOUT="${PI_DELEGATE_TIMEOUT:-30m}"
readonly STATE_ROOT="${XDG_STATE_HOME:-${HOME}/.local/state}/pi-delegate"
# The follower polls for the exit file at this interval, in seconds.
readonly POLL=1

usage() {
	echo "usage: pi-delegate [--edit] [--tmux] [--name <name>] [--base <ref>] [--] <brief | ->" >&2
	echo "       pi-delegate follow <name>" >&2
	exit 2
}

# The window's view: what the run is saying and doing, for a human.
readonly PRETTY='
	if .type == "message_update" and .assistantMessageEvent.type == "text_delta" then
		.assistantMessageEvent.delta
	elif .type == "message_end" and .message.role == "assistant" then "\n"
	elif .type == "tool_execution_start" then "\n> \(.toolName) \(.args | tostring | .[0:200])\n"
	elif .type == "tool_execution_end" and .isError then "! \(.toolName) failed\n"
	elif .type == "auto_retry_start" then "\n! retry \(.attempt)/\(.maxAttempts): \(.errorMessage)\n"
	else empty end'

# The caller's view: one line per tool call, so it can follow without paying
# for the run's reasoning.
readonly COMPACT='
	if .type == "tool_execution_start" then "tool: \(.toolName) \(.args | tostring | .[0:160])"
	elif .type == "auto_retry_start" then "retry: \(.attempt)/\(.maxAttempts) \(.errorMessage | .[0:160])"
	else empty end'

# Runs pi and records it; the rest of the script only reads what this leaves.
# In a tmux window it also shows the run, then waits for a key so the human
# can read the end of it.
run() {
	local dir="$1" status=143
	trap 'echo "${status}" >"${dir}/exit"' EXIT
	set +e
	# The brief goes in as text, not @task.md, because pi's sandbox cannot read
	# the state dir. --no-approve because pi exits 0 without running when a
	# directory's project-local files are not yet approved, and every --edit
	# worktree is new. --no-verify-guard because the allowlist leaves out its
	# verify tool and the caller verifies.
	timeout "${TIMEOUT}" pi --tools "$(<"${dir}/tools")" --model "${MODEL}" --mode json --no-session \
		--no-approve --no-verify-guard -- "$(<"${dir}/task.md")" </dev/null 2>"${dir}/stderr.log" |
		tee "${dir}/events.ndjson" |
		if [[ -t 1 ]]; then jq --unbuffered -rj "${PRETTY}"; else cat >/dev/null; fi
	status="${PIPESTATUS[0]}"
	set -e
	jq -r 'select(.type == "agent_end") | .messages[-1].content[]?
		| select(.type == "text") | .text' "${dir}/events.ndjson" >"${dir}/result.md"
	echo "${status}" >"${dir}/exit"
	trap - EXIT
	if [[ -t 1 ]]; then
		printf '\n[pi-delegate] exit %s. Press enter to close.' "${status}"
		read -r _
	fi
}

# Copies events.ndjson to stdout from the start, following it until the run
# has written its exit status. The exit file is checked before each drain, so
# the drain after it appears reaches everything the run wrote.
stream() {
	local dir="$1" line partial="" finished
	exec 3<"${dir}/events.ndjson"
	while :; do
		finished=false
		[[ -e ${dir}/exit ]] && finished=true
		# read fails at EOF, leaving any unterminated tail of a line in $line.
		while IFS= read -r line <&3; do
			printf '%s\n' "${partial}${line}"
			partial=""
		done
		partial+="${line}"
		[[ ${finished} == true ]] && break
		sleep "${POLL}"
	done
	[[ -z ${partial} ]] || printf '%s\n' "${partial}"
	exec 3<&-
}

# Streams a run's tool calls from the start, then its outcome, and exits with
# pi's status once the run has one.
follow() {
	local dir="$1" status error base
	stream "${dir}" | jq --unbuffered -r "${COMPACT}"

	status="$(<"${dir}/exit")"
	# pi exits 0 both when it never runs the agent and when the model's last
	# reply is an error it gave up retrying, so neither counts as done.
	error="$(jq -rs '[.[] | select(.type == "agent_end")] | last
		| if . == null then "no agent_end: pi never ran the agent"
		else .messages[-1] | select(.stopReason == "error" or .stopReason == "aborted")
			| .errorMessage // .stopReason end' "${dir}/events.ndjson")"
	if [[ ${status} == 0 && -n ${error} ]]; then
		status=1
	fi
	if [[ ${status} != 0 ]]; then
		echo "FAILED exit=${status}"
		[[ -z ${error} ]] || echo "${error}"
		tail -n 20 "${dir}/stderr.log"
		exit "${status}"
	fi
	jq -rs '[.[] | select(.type == "message_end" and .message.role == "assistant") | .message.usage]
		| "DONE tokens=\(map(.totalTokens) | add) cost=\(map(.cost.total) | add)"' "${dir}/events.ndjson"
	if [[ -e ${dir}/base ]]; then
		base="$(<"${dir}/base")"
		git -C "$(<"${dir}/workdir")" status --short
		git -C "$(<"${dir}/workdir")" diff --stat "${base}"
	fi
	cat "${dir}/result.md"
}

case "${1:-}" in
__run)
	run "$2"
	exit 0
	;;
follow)
	[[ $# -eq 2 && -d ${STATE_ROOT}/$2 ]] || usage
	follow "${STATE_ROOT}/$2"
	exit 0
	;;
esac

edit=false
tmux="${PI_DELEGATE_TMUX:-0}"
name=""
base=""
while [[ $# -gt 0 ]]; do
	case "$1" in
	--edit) edit=true ;;
	--tmux) tmux=1 ;;
	--name) name="$2" && shift ;;
	--base) base="$2" && shift ;;
	-h | --help) usage ;;
	--)
		shift
		break
		;;
	-) break ;;
	-*) usage ;;
	*) break ;;
	esac
	shift
done
[[ $# -eq 1 ]] || usage
if [[ $1 == - ]]; then brief="$(cat)"; else brief="$1"; fi
[[ -n ${brief} ]] || usage

name="${name:-delegate-$(date +%Y%m%d-%H%M%S)}"
if [[ ! ${name} =~ ^[a-z0-9][a-z0-9._-]*$ ]]; then
	echo "pi-delegate: name must be lowercase letters, digits, '.', '_' and '-'" >&2
	exit 2
fi
dir="${STATE_ROOT}/${name}"
if [[ -e ${dir} ]]; then
	echo "pi-delegate: ${dir} already exists" >&2
	exit 2
fi
mkdir -p "${dir}"
printf '%s\n' "${brief}" >"${dir}/task.md"

workdir="${PWD}"
if [[ ${edit} == true ]]; then
	base="${base:-$(git rev-parse --abbrev-ref HEAD)}"
	workdir="$(git wt-feature-branch --no-fetch --print-path --base "${base}" "${name}")"
	echo "${base}" >"${dir}/base"
	echo "${EDIT_TOOLS}" >"${dir}/tools"
	echo "worktree: ${workdir}"
else
	echo "${READ_TOOLS}" >"${dir}/tools"
fi
echo "${workdir}" >"${dir}/workdir"
echo "run: ${dir}"

touch "${dir}/events.ndjson"
if [[ ${tmux} == 1 ]]; then
	tmux new-window -d -n "${name}" -c "${workdir}" -- "$0" __run "${dir}"
else
	# Its own process group, so a caller killed along with its group (a
	# timed-out tool call, a closed terminal) leaves the run going.
	set -m
	(cd "${workdir}" && nohup "$0" __run "${dir}" </dev/null >/dev/null 2>&1) &
	set +m
fi
follow "${dir}"
