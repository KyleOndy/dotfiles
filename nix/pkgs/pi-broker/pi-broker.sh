# shellcheck shell=bash
# shellcheck disable=SC2016 # $names in single quotes are jq variables
# writeShellApplication provides the shebang and `set -euo pipefail`; this
# file is only the body (nix/pkgs/pi-broker/default.nix).
#
# pi-broker -- spawns and tears down a pi coordinator's agents
#
# Usage: pi-broker <coord-dir> <watch-pid> <repo-dir> <pi-bin>
#
# The pi wrapper starts this outside the sandbox for `pi --coordinator` and it
# exits when <watch-pid> does. A sandboxed coordinator cannot make a worktree
# beside its own, start a VM or open a sandbox wider than its own, so it
# writes requests and this does all three. Each agent gets:
#   - a worktree and branch named after it, based on the coordinator's HEAD,
#     under the coordinator branch's ticket when it has one (DEV-123-*)
#   - forge instance <n>, its own VM, defined but stopped until the agent
#     asks for it with forge_boot
#   - a tmux window running `pi --allow-forge=<n> --coord-child=<id>/<agent>`
#
# <coord-dir> layout, which extensions/coordinator.ts reads and writes:
#   requests/<uuid>.json   written by the coordinator, consumed here
#   responses/<uuid>.json  accepted or rejected, and why
#   state/<agent>.json     the agent's state, instance, worktree and window
#   logs/<agent>.*.log     this script's and forge's output for the agent
#   agents/<agent>/        task.md for the child, result.md from it,
#                          boot.request from it and boot.json back
#
# agents/<agent>/ is the one place the child can write, so nothing here reads
# a decision back out of it: an instance number taken from there would let a
# child aim `forge nuke` at a sibling's VM. boot.request is read for its
# presence alone.

readonly COORD_DIR="$1"
readonly WATCH_PID="$2"
readonly REPO_DIR="$3"
readonly PI_BIN="$4"
readonly COORD_ID="${COORD_DIR##*/}"

readonly MAX_AGENTS=@maxAgents@
readonly MEMORY_BUDGET_GIB=@memoryBudgetGib@
# forge's own ceiling on FORGE_INSTANCE (nix/pkgs/forge/forge.sh).
readonly MAX_INSTANCE=15
# Shared by every coordinator on this host, so two of them never hand out the
# same instance or overrun the budget between them.
readonly SLOTS_DIR="${COORD_DIR%/*}/slots"
readonly FORGE_CONFIG_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/forge"
# The wrapper's pattern for the agent path component (nix/pkgs/pi-wrapper).
readonly AGENT_RE='^[a-z0-9][a-z0-9._-]{0,63}$'
# Enough for a long brief, short of something that is not one.
readonly MAX_TASK_CHARS=65536
readonly POLL_SECONDS=2

# stderr, since several callers are read through $(...) and a log line on
# stdout would become their value.
log() { echo "[$(date -u +%FT%TZ)] $*" >&2; }

mkdir -p "${COORD_DIR}/requests" "${COORD_DIR}/responses" "${COORD_DIR}/processed" \
	"${COORD_DIR}/agents" "${COORD_DIR}/state" "${COORD_DIR}/logs" "${SLOTS_DIR}"
echo $$ >"${COORD_DIR}/broker.pid"

# ─── State files ──────────────────────────────────────────────────────────────

# Rename is atomic, so a reader sees the old file or the new one, never half.
write_json() {
	local file="$1"
	shift
	jq -n "$@" >"${file}.tmp" && mv "${file}.tmp" "${file}"
}

respond() {
	local id="$1" ok="$2" message="$3"
	write_json "${COORD_DIR}/responses/${id}.json" \
		--argjson ok "${ok}" --arg message "${message}" '{ok: $ok, message: $message}'
	log "request ${id}: ok=${ok} ${message}"
}

agent_dir() { echo "${COORD_DIR}/agents/$1"; }

# The child can plant a symlink at any name in its own directory, so the reply
# is written in state/ and renamed in: rename replaces a symlink rather than
# following it, and -T refuses to move into a directory planted there.
reply_to_child() {
	local agent="$1" name="$2" tmp
	shift 2
	tmp="$(mktemp "${COORD_DIR}/state/.reply-XXXXXX")"
	jq -n "$@" >"${tmp}"
	mv -T "${tmp}" "$(agent_dir "${agent}")/${name}" || rm -f "${tmp}"
}
state_file() { echo "${COORD_DIR}/state/$1.json"; }
log_file() { echo "${COORD_DIR}/logs/$1.$2.log"; }

# Merges fields into the agent's state file. Arguments are name/value pairs,
# each becoming a string field.
set_status() {
	local agent="$1" file
	shift
	file="$(state_file "${agent}")"
	local args=() expr='. + {updated: $updated'
	while (($#)); do
		args+=(--arg "$1" "$2")
		expr+=", $1: \$$1"
		shift 2
	done
	expr+='}'
	jq "${args[@]}" --arg updated "$(date -u +%FT%TZ)" "${expr}" "${file}" >"${file}.tmp" &&
		mv "${file}.tmp" "${file}"
}

get_status() {
	jq -r --arg k "$2" '.[$k] // empty' "$(state_file "$1")" 2>/dev/null || true
}

# ─── Slots ────────────────────────────────────────────────────────────────────

# mkdir is the one atomic test-and-set the filesystem offers without flock,
# which macOS does not ship.
lock_slots() {
	local tries=0
	until mkdir "${SLOTS_DIR}/.lock" 2>/dev/null; do
		((++tries < 300)) || {
			log "slot lock held for 30s, breaking it"
			rm -rf "${SLOTS_DIR}/.lock"
		}
		sleep 0.1
	done
}

unlock_slots() { rm -rf "${SLOTS_DIR}/.lock"; }

# forge declares the sizes, so this asks it rather than keeping a copy.
size_memory_gib() {
	local memory
	memory="$(FORGE_INSTANCE=1 forge vm-config "$1" | jq -r .memory)"
	echo "${memory%GiB}"
}

# A slot whose VM is gone and whose agent is not still being created was left
# by a failed spawn or a coordinator that died mid-teardown, or nuked by hand.
slot_is_stale() {
	local n="$1" owner state
	[[ -d "${LIMA_HOME:-${HOME}/.lima}/forge-${n}" ]] && return 1
	owner="$(cat "${SLOTS_DIR}/${n}/owner" 2>/dev/null || true)"
	state="$(jq -r '.state // empty' "${owner}" 2>/dev/null || true)"
	[[ ${state} != creating && ${state} != starting-forge ]]
}

# Prints the claimed instance, or a reason on stderr and fails. Caller holds
# the slot lock.
claim_slot() {
	local agent="$1" size="$2" want used=0 count=0 n free=""
	want="$(size_memory_gib "${size}")"
	for ((n = 1; n <= MAX_INSTANCE; n++)); do
		[[ -d "${SLOTS_DIR}/${n}" ]] || continue
		if slot_is_stale "${n}"; then
			log "reclaiming stale slot ${n} ($(cat "${SLOTS_DIR}/${n}/owner" 2>/dev/null))"
			rm -rf "${SLOTS_DIR:?}/${n}"
			continue
		fi
		count=$((count + 1))
		used=$((used + $(size_memory_gib "$(cat "${SLOTS_DIR}/${n}/size")")))
	done
	if ((count >= MAX_AGENTS)); then
		echo "all ${MAX_AGENTS} agent slots are in use" >&2
		return 1
	fi
	if ((used + want > MEMORY_BUDGET_GIB)); then
		echo "a ${size} VM needs ${want}GiB and ${used} of ${MEMORY_BUDGET_GIB}GiB is in use" >&2
		return 1
	fi
	# A VM nobody holds a slot for is someone's hand-made instance: skip it.
	for ((n = 1; n <= MAX_INSTANCE; n++)); do
		if [[ ! -d "${SLOTS_DIR}/${n}" && ! -d "${LIMA_HOME:-${HOME}/.lima}/forge-${n}" ]]; then
			free="${n}"
			break
		fi
	done
	if [[ -z ${free} ]]; then
		echo "no forge instance 1-${MAX_INSTANCE} is free" >&2
		return 1
	fi
	mkdir "${SLOTS_DIR}/${free}"
	state_file "${agent}" >"${SLOTS_DIR}/${free}/owner"
	echo "${size}" >"${SLOTS_DIR}/${free}/size"
	echo "${free}"
}

# Only the slot's own agent may release it: a stale reclaim may have handed
# the number to someone else since.
release_slot() {
	local n="$1" agent="$2"
	[[ -n ${n} ]] || return 0
	lock_slots
	if [[ "$(cat "${SLOTS_DIR}/${n}/owner" 2>/dev/null)" == "$(state_file "${agent}")" ]]; then
		rm -rf "${SLOTS_DIR:?}/${n}"
	fi
	unlock_slots
}

# ─── tmux ─────────────────────────────────────────────────────────────────────

# The coordinator's own session when it runs inside tmux, otherwise one made
# for it. Resolved once, so every agent lands beside the others, and called
# only from the main loop, so two spawns cannot both create it.
tmux_target() {
	local file="${COORD_DIR}/tmux-session" session
	if [[ -s ${file} ]] && tmux has-session -t "$(cat "${file}")" 2>/dev/null; then
		cat "${file}"
		return
	fi
	if [[ -n ${TMUX:-} ]]; then
		session="$(tmux display-message -p '#{session_id}')"
	else
		session="pi-${COORD_ID}"
		tmux new-session -d -s "${session}" -c "${REPO_DIR}"
		log "no tmux session to join, agents run in '${session}'"
	fi
	echo "${session}" >"${file}"
	echo "${session}"
}

window_alive() {
	[[ -n $1 ]] && tmux list-windows -a -F '#{window_id}' 2>/dev/null | grep -qxF "$1"
}

# ─── Spawn ────────────────────────────────────────────────────────────────────

# small takes forge-small.yaml when one is installed, since a 4GiB VM does not
# hold the five nodes forge.yaml declares.
forge_config_for() {
	if [[ $1 == small && -f "${FORGE_CONFIG_DIR}/forge-small.yaml" ]]; then
		echo "${FORGE_CONFIG_DIR}/forge-small.yaml"
	else
		echo "${FORGE_CONFIG_DIR}/forge.yaml"
	fi
}

# Runs in the background: worktree, then VM, then window. A failure leaves the
# worktree for the coordinator to inspect or tear down, and gives back the VM
# and slot before it reports failed, so failed means there is room again.
run_spawn() {
	local agent="$1" instance="$2" size="$3" base="$4" target="$5" ticket="$6" dir worktree window blog flog
	dir="$(agent_dir "${agent}")"
	blog="$(log_file "${agent}" broker)"
	flog="$(log_file "${agent}" forge)"

	if ! worktree="$(git -C "${REPO_DIR}" wt-feature-branch --no-fetch --print-path \
		--base "${base}" ${ticket:+"${ticket}"} "${agent}" 2>>"${blog}")"; then
		release_slot "${instance}" "${agent}"
		set_status "${agent}" state failed error "worktree creation failed, see ${blog}"
		return
	fi
	set_status "${agent}" state starting-forge worktree "${worktree}"

	# init also saves the config into the instance's directory, which is what
	# the agent's own `forge up` reads.
	if ! FORGE_INSTANCE="${instance}" FORGE_CONFIG="$(forge_config_for "${size}")" \
		forge init --size "${size}" >>"${flog}" 2>&1; then
		FORGE_INSTANCE="${instance}" forge nuke >>"${flog}" 2>&1 || true
		release_slot "${instance}" "${agent}"
		set_status "${agent}" state failed error "forge init failed, see ${flog}"
		return
	fi

	if ! window="$(tmux new-window -d -P -F '#{window_id}' -t "${target}:" \
		-n "${agent}" -c "${worktree}" -- \
		"${PI_BIN}" --allow-forge="${instance}" --coord-child="${COORD_ID}/${agent}" \
		--name "${agent}" "@${dir}/task.md" 2>>"${blog}")"; then
		set_status "${agent}" state failed error "tmux new-window failed, see ${blog}"
		return
	fi
	set_status "${agent}" state running window "${window}" vm stopped
}

handle_spawn() {
	local id="$1" file="$2" agent task size base instance reason dir target ticket="" branch
	agent="$(jq -r '.agent // ""' "${file}")"
	task="$(jq -r '.task // ""' "${file}")"
	size="$(jq -r '.size // "small"' "${file}")"
	base="$(jq -r '.base // ""' "${file}")"

	if [[ ! ${agent} =~ ${AGENT_RE} ]] || ! git check-ref-format --branch "${agent}" >/dev/null 2>&1; then
		respond "${id}" false "agent name must match ${AGENT_RE} and be a valid branch name"
		return
	fi
	if [[ -e "$(state_file "${agent}")" || -e "$(agent_dir "${agent}")" ]]; then
		respond "${id}" false "agent ${agent} already exists; tear it down or pick another name"
		return
	fi
	if [[ -z ${task} || ${#task} -gt ${MAX_TASK_CHARS} ]]; then
		respond "${id}" false "task must be 1-${MAX_TASK_CHARS} characters"
		return
	fi
	if [[ ${size} != small && ${size} != large ]]; then
		respond "${id}" false "size must be small or large"
		return
	fi
	# A leading dash would read as an option to git, and the coordinator's own
	# HEAD is what an agent without a base should start from.
	[[ -n ${base} ]] || base="$(git -C "${REPO_DIR}" rev-parse --abbrev-ref HEAD)"
	if [[ ${base} == -* ]] || ! git -C "${REPO_DIR}" rev-parse --verify --quiet "${base}^{commit}" >/dev/null; then
		respond "${id}" false "base '${base}' is not a commit in ${REPO_DIR}"
		return
	fi

	# git-wt-feature-branch's work mode, so the agent's branch carries the
	# ticket id Linear links pull requests by.
	if [[ "$(git -C "${REPO_DIR}" symbolic-ref --short -q HEAD)" =~ ^([A-Z]+-[0-9]+)- ]]; then
		ticket="${BASH_REMATCH[1]}"
	fi
	branch="${ticket:+${ticket}-}${agent}"

	lock_slots
	if ! instance="$(claim_slot "${agent}" "${size}" 2>"${COORD_DIR}/.claim-error")"; then
		unlock_slots
		reason="$(cat "${COORD_DIR}/.claim-error")"
		respond "${id}" false "no room: ${reason}"
		return
	fi
	dir="$(agent_dir "${agent}")"
	mkdir -p "${dir}"
	unlock_slots

	printf '%s\n' "${task}" >"${dir}/task.md"
	write_json "$(state_file "${agent}")" \
		--arg agent "${agent}" --arg instance "${instance}" --arg size "${size}" \
		--arg base "${base}" --arg branch "${branch}" --arg updated "$(date -u +%FT%TZ)" \
		'{agent: $agent, state: "creating", instance: $instance, size: $size,
		  base: $base, branch: $branch, updated: $updated}'
	target="$(tmux_target)"
	respond "${id}" true "agent ${agent} on forge instance ${instance} (${size}), based on ${base}"
	run_spawn "${agent}" "${instance}" "${size}" "${base}" "${target}" "${ticket}" &
}

# ─── Boot ─────────────────────────────────────────────────────────────────────

# Booting needs ~/.lima, which the child's sandbox denies. Clusters do not:
# the child runs `forge up` itself once the socket answers.
run_boot() {
	local agent="$1" instance flog
	instance="$(get_status "${agent}" instance)"
	flog="$(log_file "${agent}" forge)"
	if forge cache up >>"${flog}" 2>&1 && FORGE_INSTANCE="${instance}" forge start >>"${flog}" 2>&1; then
		set_status "${agent}" vm running
		reply_to_child "${agent}" boot.json --arg m "forge instance ${instance} is running; 'forge up' builds its clusters" \
			'{ok: true, message: $m}'
	else
		set_status "${agent}" vm boot-failed error "forge start failed, see ${flog}"
		reply_to_child "${agent}" boot.json \
			--arg m "forge instance ${instance} did not boot; the coordinator's agent_status has the log path" \
			'{ok: false, message: $m}'
	fi
}

boot_requested() {
	local status agent request
	for status in "${COORD_DIR}"/state/*.json; do
		[[ -f ${status} ]] || continue
		[[ "$(jq -r .state "${status}")" == running ]] || continue
		agent="$(basename "${status}" .json)"
		request="$(agent_dir "${agent}")/boot.request"
		[[ -e ${request} || -L ${request} ]] || continue
		rm -rf "${request}"
		[[ "$(get_status "${agent}" vm)" != booting ]] || continue
		set_status "${agent}" vm booting
		run_boot "${agent}" &
	done
}

# ─── Teardown ─────────────────────────────────────────────────────────────────

# Never forces the worktree: `git worktree remove` refuses one with changes,
# and the branch is always kept, since either may hold the only copy of the
# agent's work.
run_teardown() {
	local agent="$1" remove_worktree="$2" instance window worktree error="" blog flog
	blog="$(log_file "${agent}" broker)"
	flog="$(log_file "${agent}" forge)"
	instance="$(get_status "${agent}" instance)"
	window="$(get_status "${agent}" window)"
	worktree="$(get_status "${agent}" worktree)"

	if window_alive "${window}"; then
		tmux kill-window -t "${window}" 2>>"${blog}" || true
	fi
	if [[ -n ${instance} ]]; then
		FORGE_INSTANCE="${instance}" forge nuke >>"${flog}" 2>&1 ||
			error="forge nuke failed, see ${flog}. "
		release_slot "${instance}" "${agent}"
	fi
	if [[ ${remove_worktree} == true && -n ${worktree} ]]; then
		git -C "${REPO_DIR}" worktree remove "${worktree}" 2>>"${blog}" ||
			error+="worktree kept: git refused to remove ${worktree}, see ${blog}."
	fi
	set_status "${agent}" state torn-down error "${error}"
}

handle_teardown() {
	local id="$1" file="$2" agent remove_worktree
	agent="$(jq -r '.agent // ""' "${file}")"
	remove_worktree="$(jq -r '.remove_worktree == true' "${file}")"
	if [[ ! ${agent} =~ ${AGENT_RE} || ! -f "$(state_file "${agent}")" ]]; then
		respond "${id}" false "no agent named '${agent}'"
		return
	fi
	case "$(get_status "${agent}" state)" in
	creating | starting-forge)
		respond "${id}" false "agent ${agent} is still starting; tear it down once it is running or failed"
		return
		;;
	torn-down)
		respond "${id}" false "agent ${agent} is already torn down"
		return
		;;
	esac
	set_status "${agent}" state tearing-down
	respond "${id}" true "tearing down ${agent}"
	run_teardown "${agent}" "${remove_worktree}" &
}

# ─── Loop ─────────────────────────────────────────────────────────────────────

# The request leaves requests/ before it is parsed, so a broker that dies
# partway through does not handle it twice.
handle_request() {
	local file="$1" id moved
	id="$(basename "${file}" .json)"
	moved="${COORD_DIR}/processed/${id}.json"
	mv "${file}" "${moved}" || return 0
	# The coordinator can write requests/ but read little else. A symlink here
	# would have this unsandboxed process read its target and echo a field of
	# it back in a response.
	if [[ -L ${moved} || ! -f ${moved} ]]; then
		rm -f "${moved}"
		respond "${id}" false "request is not a regular file"
		return
	fi
	if ! jq -e 'type == "object"' "${moved}" >/dev/null 2>&1; then
		respond "${id}" false "request is not a JSON object"
		return
	fi
	case "$(jq -r '.op // ""' "${moved}")" in
	spawn) handle_spawn "${id}" "${moved}" ;;
	teardown) handle_teardown "${id}" "${moved}" ;;
	*) respond "${id}" false "op must be spawn or teardown" ;;
	esac
}

# A child that quit without calling report_result closes its window and
# leaves nothing behind, so notice the window going.
reap_exited() {
	local status agent window
	for status in "${COORD_DIR}"/state/*.json; do
		[[ -f ${status} ]] || continue
		[[ "$(jq -r .state "${status}")" == running ]] || continue
		agent="$(basename "${status}" .json)"
		window="$(get_status "${agent}" window)"
		if ! window_alive "${window}"; then
			if [[ -f "$(agent_dir "${agent}")/result.md" ]]; then
				set_status "${agent}" state "done"
			else
				set_status "${agent}" state exited error "pi exited without reporting a result"
			fi
		fi
	done
}

log "broker for ${COORD_ID} (pid $$), watching pid ${WATCH_PID}, repo ${REPO_DIR}"
while kill -0 "${WATCH_PID}" 2>/dev/null; do
	for request in "${COORD_DIR}"/requests/*.json; do
		[[ -e ${request} ]] || continue
		handle_request "${request}"
	done
	reap_exited
	boot_requested
	sleep "${POLL_SECONDS}"
done
rm -f "${COORD_DIR}/broker.pid"
log "coordinator exited; agents keep running, 'pi --coordinator=${COORD_ID}' picks them up"
