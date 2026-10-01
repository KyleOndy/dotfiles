# shellcheck shell=bash
# writeShellApplication provides the shebang and `set -euo pipefail`; this
# file is only the body (nix/pkgs/pi-delegate/default.nix).
#
# pi-delegate -- hand well-defined jobs to a headless pi run
#
# Usage: pi-delegate [--edit] [--tmux] [--name <name>] [--base <ref>] [--] <brief | ->
#        pi-delegate send <name> <message | ->
#        pi-delegate follow <name>
#        pi-delegate stop <name>
#        pi-delegate ls
#
# Built for another agent (Claude Code) to call: each command that waits
# prints one line per tool the run calls, then the turn's outcome, and exits
# 0 only when the turn finished cleanly. Read-only by default, in the current
# directory. --edit gives it bash, edit and write, and always in a new
# worktree and branch named <name> off <base>, so the caller's checkout is
# never touched. --tmux, or PI_DELEGATE_TMUX=1, also shows the run in a tmux
# window; without it the run is headless. Either way the run outlives its
# caller.
#
# pi runs in RPC mode (pi's docs/rpc.md), reading commands from a FIFO. The
# brief is the first turn. Once a turn settles, the run stays open for
# PI_DELEGATE_IDLE seconds, and `send` starts another turn in the same
# session, or steers the one in progress. After that, pi's stdin is closed
# and it exits.
#
# Each run leaves <state>/<name>/ behind:
#   task.md          the brief
#   in               the FIFO pi reads commands from
#   events.ndjson    pi's stdout, the full record; turn N ends at its Nth
#                    agent_settled event
#   stderr.log       pi's stderr
#   pid              the process pi runs under
#   workdir, base    where it ran, and the ref an --edit branch started from
#   stop             `stop` was asked for
#   closed           pi's stdin is closed, so it takes no more commands
#   exit             pi's exit status, written last; 124 when it timed out

readonly MODEL="${PI_DELEGATE_MODEL:-mcloud/zai-org/glm-5.3}"
readonly READ_TOOLS="read,grep,find,ls"
readonly EDIT_TOOLS="read,grep,find,ls,edit,write,bash"
# Wall clock for the whole run, idle time included. A model can stall
# mid-stream or loop inside a tool call and never end its turn.
readonly TIMEOUT="${PI_DELEGATE_TIMEOUT:-30m}"
# Seconds a settled run waits for `send` before closing.
readonly IDLE="${PI_DELEGATE_IDLE:-300}"
readonly STATE_ROOT="${XDG_STATE_HOME:-${HOME}/.local/state}/pi-delegate"
# Followers poll events.ndjson at this interval, in seconds.
readonly POLL=1
# Seconds `stop` waits for an aborted run to exit before killing it.
readonly STOP_GRACE=30
readonly SETTLED='"type":"agent_settled"'

usage() {
	cat >&2 <<-EOF
		usage: pi-delegate [--edit] [--tmux] [--name <name>] [--base <ref>] [--] <brief | ->
		       pi-delegate send <name> <message | ->
		       pi-delegate follow <name>
		       pi-delegate stop <name>
		       pi-delegate ls
	EOF
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
	elif .type == "response" and .success == false then "\n! \(.command) rejected: \(.error)\n"
	else empty end'

# The caller's view: one line per tool call, so it can follow without paying
# for the run's reasoning.
readonly COMPACT='
	if .type == "tool_execution_start" then "tool: \(.toolName) \(.args | tostring | .[0:160])"
	elif .type == "auto_retry_start" then "retry: \(.attempt)/\(.maxAttempts) \(.errorMessage | .[0:160])"
	elif .type == "response" and .success == false then "rejected: \(.command) \(.error)"
	elif .type == "extension_ui_request" and (.method | IN("select", "confirm", "input", "editor")) then
		"ui: \(.method) \(.title // "") (cancelled)"
	else empty end'

# The supervisor's view: only the records it acts on, one short line each.
# Dialogs block pi until answered, and a caller is never around to answer.
readonly CONTROL='
	if .type == "agent_start" or .type == "agent_settled" then "\(.type) -"
	elif .type == "response" and .id == "brief" and .success == false then "brief_rejected -"
	elif .type == "response" then "response -"
	elif .type == "extension_ui_request" and (.method | IN("select", "confirm", "input", "editor")) then
		"dialog \(.id)"
	else empty end'

# Holds pi's stdin open, sends the brief, cancels dialogs, and closes stdin
# once the run is settled and either idle past IDLE or asked to stop. Reads
# CONTROL lines on stdin, and drains them to EOF after closing.
supervise() {
	local dir="$1" type id settled=false
	# Read-write, so opening does not wait for pi and pi sees no EOF between
	# one `send` closing the FIFO and the next opening it.
	exec 3<>"${dir}/in"
	jq -nc --rawfile m "${dir}/task.md" '{id: "brief", type: "prompt", message: $m}' >&3
	while :; do
		if [[ ${settled} == true ]]; then
			[[ ! -e ${dir}/stop ]] || break
			read -r -t "${IDLE}" type id || break
		else
			read -r type id || break
		fi
		case "${type}" in
		agent_start) settled=false ;;
		agent_settled) settled=true ;;
		brief_rejected) break ;;
		dialog) jq -nc --arg id "${id}" '{type: "extension_ui_response", id: $id, cancelled: true}' >&3 ;;
		esac
	done
	touch "${dir}/closed"
	exec 3>&-
	cat >/dev/null
}

# Runs pi and records it; the rest of the script only reads what this leaves.
# In a tmux window it also shows the run, then waits for a key so the human
# can read the end of it.
run() {
	local dir="$1" status=143 view=()
	trap 'echo "${status}" >"${dir}/exit"' EXIT
	if [[ -t 1 ]]; then
		exec 4> >(jq --unbuffered -rj "${PRETTY}")
		view=(/dev/fd/4)
	fi
	set +e
	# --no-approve because pi exits 0 without running when a directory's
	# project-local files are not yet approved, and every --edit worktree is
	# new. --no-verify-guard because the allowlist leaves out its verify tool
	# and the caller verifies.
	# cat relays the FIFO into a pipe: pi, reading the FIFO itself, never sees
	# EOF on macOS once the last writer closes, and so never exits.
	cat "${dir}/in" |
		(
			echo "${BASHPID}" >"${dir}/pid"
			exec timeout "${TIMEOUT}" pi --tools "$(<"${dir}/tools")" --model "${MODEL}" --mode rpc \
				--no-session --no-approve --no-verify-guard 2>"${dir}/stderr.log"
		) |
		tee "${dir}/events.ndjson" "${view[@]}" |
		jq --unbuffered -r "${CONTROL}" |
		supervise "${dir}"
	status="${PIPESTATUS[1]}"
	set -e
	echo "${status}" >"${dir}/exit"
	trap - EXIT
	if [[ -t 1 ]]; then
		exec 4>&-
		printf '\n[pi-delegate] exit %s. Press enter to close.' "${status}"
		read -r _
	fi
}

settles() { grep -c "${SETTLED}" "${dir}/events.ndjson" || true; }

# Line number of the Nth agent_settled event, empty when there is none yet.
settle_line() { { grep -n "${SETTLED}" "${dir}/events.ndjson" || true; } | sed -n "${1}s/:.*//p"; }

# Line number of the last agent_start event, 0 when there is none.
last_start() {
	local n
	n="$({ grep -n '"type":"agent_start"' "${dir}/events.ndjson" || true; } | tail -n 1 | cut -d: -f1)"
	echo "${n:-0}"
}

# Whether a turn is in progress, or the brief has yet to become one.
running() {
	local count
	count="$(settles)"
	((count == 0)) || (($(last_start) > $(settle_line "${count}")))
}

# Copies events.ndjson from line $2 to stdout, following it until turn $1 has
# settled, the run has exited, or the prompt with id $3 was rejected. The exit
# file is checked before each drain, so the drain after it appears reaches
# everything the run wrote.
stream() {
	local target="$1" from="$2" id="${3:-}" line partial="" finished n=0 seen=0
	exec 3<"${dir}/events.ndjson"
	while :; do
		finished=false
		[[ -e ${dir}/exit ]] && finished=true
		# read fails at EOF, leaving any unterminated tail of a line in $line.
		while IFS= read -r line <&3; do
			line="${partial}${line}"
			partial=""
			n=$((n + 1))
			((n < from)) || printf '%s\n' "${line}"
			if [[ ${line} == *"${SETTLED}"* ]]; then
				seen=$((seen + 1))
				((seen < target)) || break 2
			elif [[ -n ${id} && ${line} == *'"type":"response"'* && ${line} == *"\"id\":\"${id}\""* &&
				${line} == *'"success":false'* ]]; then
				break 2
			fi
		done
		partial+="${line}"
		[[ ${finished} == true ]] && break
		sleep "${POLL}"
	done
	exec 3<&-
}

# Prints turn $1's tool calls from line $2 as they happen, then its outcome,
# and exits 0 only if it settled with a reply that is not an error. $3 is the
# id of the prompt that started it, if this caller sent one.
await() {
	local target="$1" from="$2" id="${3:-}" first=1 last status error base
	stream "${target}" "${from}" "${id}" | jq --unbuffered -r "${COMPACT}"

	((target == 1)) || first=$(($(settle_line $((target - 1))) + 1))
	last="$(settle_line "${target}")"
	# pi exits 0 both when the brief never becomes a turn and when the model's
	# last reply is an error it gave up retrying, so neither counts as done.
	error="$(sed -n "${first},${last:-\$}p" "${dir}/events.ndjson" | jq -rs '
		([.[] | select(.type == "response" and .success == false)] | last | .error // empty),
		([.[] | select(.type == "agent_end")] | last | .messages[-1]?
			| select(.stopReason == "error" or .stopReason == "aborted") | .errorMessage // .stopReason)')"
	status=0
	if [[ -z ${last} ]]; then
		status=1
		[[ ! -e ${dir}/exit || $(<"${dir}/exit") == 0 ]] || status="$(<"${dir}/exit")"
		error="${error:-pi exited before turn ${target} settled}"
	elif [[ -n ${error} ]]; then
		status=1
	fi
	if [[ ${status} != 0 ]]; then
		echo "FAILED turn=${target} exit=${status}"
		echo "${error}"
		tail -n 20 "${dir}/stderr.log"
		exit "${status}"
	fi

	sed -n "${first},${last}p" "${dir}/events.ndjson" | jq -rs --arg turn "${target}" '
		[.[] | select(.type == "message_end" and .message.role == "assistant") | .message.usage]
		| "DONE turn=\($turn) tokens=\(map(.totalTokens) | add) cost=\(map(.cost.total) | add)"'
	if [[ -e ${dir}/base ]]; then
		base="$(<"${dir}/base")"
		git -C "$(<"${dir}/workdir")" status --short
		git -C "$(<"${dir}/workdir")" diff --stat "${base}"
	fi
	sed -n "${first},${last}p" "${dir}/events.ndjson" | jq -rs '
		[.[] | select(.type == "agent_end")] | last | .messages[-1].content[]?
		| select(.type == "text") | .text'
	if [[ ! -e ${dir}/closed ]]; then
		echo "open: pi-delegate send ${name} <message>, closes after ${IDLE}s idle"
	fi
}

# The turn in progress, or the last one when the run is settled or over.
follow() {
	local target
	target="$(settles)"
	! running || target=$((target + 1))
	if ((target == 1)); then
		await 1 1
	else
		await "${target}" $(($(settle_line $((target - 1))) + 1))
	fi
}

# Starts a turn with $1, or steers the one in progress with it, then awaits
# that turn.
send() {
	local message="$1" id count from
	if [[ -e ${dir}/closed || -e ${dir}/exit ]]; then
		echo "pi-delegate: ${name} has ended; start a new run" >&2
		exit 2
	fi
	id="send-$(date +%s%N)"
	count="$(settles)"
	from=$(($(wc -l <"${dir}/events.ndjson") + 1))
	jq -nc --arg id "${id}" --arg m "${message}" \
		'{id: $id, type: "prompt", message: $m, streamingBehavior: "steer"}' |
		timeout 5 tee "${dir}/in" >/dev/null
	await $((count + 1)) "${from}" "${id}"
}

# Aborts the turn in progress and closes the run, killing it when it does not
# exit within STOP_GRACE.
stop() {
	local i
	if [[ ! -e ${dir}/exit ]]; then
		touch "${dir}/stop"
		echo '{"type":"abort"}' | timeout 5 tee "${dir}/in" >/dev/null || true
		for ((i = 0; i < STOP_GRACE; i++)); do
			[[ ! -e ${dir}/exit ]] || break
			sleep 1
		done
		[[ -e ${dir}/exit ]] || kill "$(<"${dir}/pid")" 2>/dev/null || true
		for ((i = 0; i < 5; i++)); do
			[[ ! -e ${dir}/exit ]] || break
			sleep 1
		done
	fi
	echo "stopped ${name} exit=$(cat "${dir}/exit" 2>/dev/null || echo unknown)"
}

list() {
	local d state
	for d in "${STATE_ROOT}"/*/; do
		[[ -d ${d} ]] || continue
		dir="${d%/}"
		if [[ -e ${dir}/exit ]]; then
			state="exited:$(<"${dir}/exit")"
		elif running; then
			state=running
		else
			state=open
		fi
		printf '%s\t%s\tturns=%s\t%s\n' "${dir##*/}" "${state}" "$(settles)" "$(<"${dir}/workdir")"
	done
}

# Sets name and dir for a subcommand's run, which must exist.
use_run() {
	[[ -n ${1:-} && -d ${STATE_ROOT}/$1 ]] || usage
	name="$1"
	dir="${STATE_ROOT}/$1"
}

case "${1:-}" in
__run)
	run "$2"
	exit 0
	;;
follow | stop)
	[[ $# -eq 2 ]] || usage
	use_run "$2"
	"$1"
	exit 0
	;;
send)
	[[ $# -eq 3 ]] || usage
	use_run "$2"
	if [[ $3 == - ]]; then message="$(cat)"; else message="$3"; fi
	[[ -n ${message} ]] || usage
	send "${message}"
	exit 0
	;;
ls)
	list
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

mkfifo "${dir}/in"
touch "${dir}/events.ndjson"
if [[ ${tmux} == 1 ]]; then
	tmux new-window -d -n "${name}" -c "${workdir}" -- "$0" __run "${dir}"
else
	# Its own process group, so a caller killed along with its group (a
	# timed-out tool call, a closed terminal) leaves the run going.
	set -m
	(cd "${workdir}" && exec nohup "$0" __run "${dir}") </dev/null >/dev/null 2>&1 &
	set +m
fi
await 1 1
