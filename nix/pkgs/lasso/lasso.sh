#!/usr/bin/env bash
# lasso — K8s Ralph Loop Harness
# Invokes Claude Code in a loop until all verification checks pass.
set -euo pipefail

LASSO_COLIMA_PROFILE="${LASSO_COLIMA_PROFILE:-lasso}"
LASSO_LOG_DIR="${LASSO_LOG_DIR:-${HOME}/.local/share/lasso/runs}"
LASSO_CONFIG="${LASSO_CONFIG:-${HOME}/.config/lasso/config}"

# PID of the current claude invocation, for cleanup on interrupt
_CLAUDE_PID=""

_cleanup() {
	echo ""
	echo "lasso: interrupted"
	if [[ -n ${_CLAUDE_PID} ]] && kill -0 "${_CLAUDE_PID}" 2>/dev/null; then
		echo "lasso: stopping claude (pid ${_CLAUDE_PID})..."
		kill "${_CLAUDE_PID}" 2>/dev/null || true
	fi
	exit 130
}

trap _cleanup INT TERM

_display_stream() {
	jq --unbuffered -r '
      if .type == "assistant" then
        (.message.content // [])[] |
        if .type == "text" then "  " + .text
        elif .type == "tool_use" then "  [tool: " + .name + "]"
        else empty
        end
      elif .type == "result" then
        "  [done — cost: $" + ((.total_cost_usd // 0) | tostring) + "]"
      else empty
      end
    ' 2>/dev/null
}

usage() {
	cat <<'EOF'
Usage: lasso <command> [options]

Commands:
  up                          Start k3s cluster via Colima (dedicated profile)
  down                        Stop the cluster
  status                      Show cluster info
  run [flags] "task"          Execute the Ralph Loop

Run flags:
  --check <cmd>               Verification command (repeatable, all must exit 0)
  --task-file <path>          Source a file for LASSO_CHECKS and LASSO_CONTEXT
  --max-iterations <n>        Maximum loop iterations (default: 10)
  --timeout <secs>            Per-Claude invocation timeout in seconds (default: 300)
  --no-sandbox                Disable macOS Seatbelt sandbox (not recommended)

Task file format (bash):
  LASSO_CONTEXT='You have a running k3s cluster.'
  LASSO_CHECKS=(
      "kubeconform -strict manifests/"
      "kubectl apply --dry-run=server -f manifests/"
  )

Examples:
  lasso up
  lasso run --check "kubeconform -strict manifests/" "Create nginx Deployment"
  lasso run --task-file ~/lasso-tasks/checks.sh "Add resource limits"
  lasso down
EOF
}

# ── cluster management ────────────────────────────────────────────────────────

cmd_up() {
	echo "lasso: starting k3s cluster (colima profile: ${LASSO_COLIMA_PROFILE})"
	if colima status --profile "${LASSO_COLIMA_PROFILE}" &>/dev/null; then
		echo "lasso: cluster already running"
		return 0
	fi
	colima start \
		--profile "${LASSO_COLIMA_PROFILE}" \
		--kubernetes \
		--cpu 2 \
		--memory 4
	echo "lasso: waiting for cluster to be ready..."
	_wait_for_cluster
	echo "lasso: cluster ready"
}

cmd_down() {
	echo "lasso: stopping cluster (colima profile: ${LASSO_COLIMA_PROFILE})"
	colima stop --profile "${LASSO_COLIMA_PROFILE}"
	echo "lasso: cluster stopped"
}

cmd_status() {
	echo "=== Colima status ==="
	colima status --profile "${LASSO_COLIMA_PROFILE}" || true
	echo ""
	echo "=== Kubernetes nodes ==="
	kubectl get nodes 2>/dev/null || echo "(cluster not reachable)"
	echo ""
	echo "=== Kubernetes namespaces ==="
	kubectl get namespaces 2>/dev/null || echo "(cluster not reachable)"
}

# ── helpers ───────────────────────────────────────────────────────────────────

_wait_for_cluster() {
	local attempts=0
	local max_attempts=30
	until kubectl get nodes &>/dev/null; do
		attempts=$((attempts + 1))
		if [[ ${attempts} -ge ${max_attempts} ]]; then
			echo "lasso: timed out waiting for cluster" >&2
			exit 1
		fi
		sleep 2
	done
	# Wait for node to be Ready
	kubectl wait --for=condition=Ready node --all --timeout=120s
}

_ensure_cluster_up() {
	if ! colima status --profile "${LASSO_COLIMA_PROFILE}" &>/dev/null; then
		echo "lasso: cluster not running, starting..."
		cmd_up
	else
		_wait_for_cluster
	fi
}

_run_checks() {
	local -a checks=("$@")
	local all_passed=true
	local failures=""

	for check in "${checks[@]}"; do
		echo "lasso: running check: ${check}"
		local output
		if output=$(eval "${check}" 2>&1); then
			echo "lasso: PASS: ${check}"
		else
			echo "lasso: FAIL: ${check}"
			all_passed=false
			failures+="=== FAILED: ${check} ===\n${output}\n\n"
		fi
	done

	if [[ ${all_passed} == "true" ]]; then
		return 0
	else
		printf "%s" "${failures}"
		return 1
	fi
}

_init_scratchpad() {
	local scratchpad="$1"
	local task="$2"
	local -a checks=("${@:3}")

	if [[ -f ${scratchpad} ]]; then
		return 0
	fi

	{
		echo "# Lasso Scratchpad"
		echo ""
		echo "**Task:** ${task}"
		echo ""
		echo "**Checks that must pass:**"
		# shellcheck disable=SC2016  # backticks are literal markdown, not command substitution
		env printf '- `%s`\n' "${checks[@]}"
		echo ""
		echo "---"
		echo ""
	} >"${scratchpad}"
}

_append_check_results() {
	local scratchpad="$1"
	local passed="$2"
	local check_output="$3"

	{
		echo ""
		echo "### Check Results"
		if [[ ${passed} == "true" ]]; then
			echo "All checks PASSED."
		else
			echo '```'
			echo "${check_output}"
			echo '```'
		fi
		echo ""
	} >>"${scratchpad}"
}

_build_prompt() {
	local task="$1"
	local context="$2"
	local iteration="$3"
	local scratchpad="$4"

	local prompt=""

	if [[ -n ${context} ]]; then
		prompt+="${context}\n\n"
	fi

	prompt+="Task: ${task}\n\n"

	prompt+="## Scratchpad\n\n"
	prompt+="A file called ${scratchpad} exists in the working directory. "
	prompt+="Read it FIRST — it contains the task definition, check commands, "
	prompt+="and notes from previous iterations.\n\n"

	if [[ ${iteration} -gt 1 ]]; then
		prompt+="This is iteration ${iteration}. Previous checks failed. "
		prompt+="Read the scratchpad to see what was tried and what went wrong. "
		prompt+="Do not repeat the same approach if it already failed.\n\n"
	fi

	prompt+="Before you finish, append a section to ${scratchpad} under "
	prompt+="'## Iteration ${iteration}' with a '### Agent Notes' subsection "
	prompt+="documenting: what you did, what you learned, and any gotchas for "
	prompt+="future iterations.\n"

	printf "%s" "${prompt}"
}

# ── sandbox ───────────────────────────────────────────────────────────────────

_sandbox_settings() {
	cat <<'SETTINGS'
{
  "sandbox": {
    "enabled": true,
    "autoAllowBashIfSandboxed": true,
    "allowUnsandboxedCommands": false,
    "excludedCommands": [],
    "network": {
      "allowedDomains": [],
      "allowUnixSockets": [],
      "allowAllUnixSockets": false,
      "allowLocalBinding": true
    }
  }
}
SETTINGS
}

# ── run loop ──────────────────────────────────────────────────────────────────

cmd_run() {
	# Defaults
	local max_iterations=10
	local timeout=300
	local task_file=""
	local task=""
	local sandbox=true
	local -a cli_checks=()

	# Load user config if present
	# shellcheck source=/dev/null
	[[ -f ${LASSO_CONFIG} ]] && source "${LASSO_CONFIG}"

	# Initialize LASSO_CHECKS and LASSO_CONTEXT if not set
	: "${LASSO_CONTEXT:=}"
	if [[ -z ${LASSO_CHECKS+x} ]]; then
		LASSO_CHECKS=()
	fi

	# Parse flags
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--check)
			cli_checks+=("$2")
			shift 2
			;;
		--task-file)
			task_file="$2"
			shift 2
			;;
		--max-iterations)
			max_iterations="$2"
			shift 2
			;;
		--timeout)
			timeout="$2"
			shift 2
			;;
		--no-sandbox)
			sandbox=false
			shift
			;;
		--help | -h)
			usage
			exit 0
			;;
		-*)
			echo "lasso: unknown flag: $1" >&2
			exit 1
			;;
		*)
			task="$1"
			shift
			;;
		esac
	done

	# Source task file (overrides config, before CLI flags)
	if [[ -n ${task_file} ]]; then
		if [[ ! -f ${task_file} ]]; then
			echo "lasso: task file not found: ${task_file}" >&2
			exit 1
		fi
		# shellcheck source=/dev/null
		source "${task_file}"
	fi

	# CLI --check flags override/append
	if [[ ${#cli_checks[@]} -gt 0 ]]; then
		LASSO_CHECKS=("${cli_checks[@]}")
	fi

	if [[ -z ${task} ]]; then
		echo "lasso: task description is required" >&2
		usage >&2
		exit 1
	fi

	if [[ ${#LASSO_CHECKS[@]} -eq 0 ]]; then
		echo "lasso: warning: no checks defined; loop will exit after first Claude invocation"
	fi

	# Set up log directory for this run
	local run_id
	run_id=$(date +%Y%m%dT%H%M%S)
	local run_dir="${LASSO_LOG_DIR}/${run_id}"
	mkdir -p "${run_dir}"
	echo "lasso: logs → ${run_dir}"

	# Ensure cluster is available
	_ensure_cluster_up

	local scratchpad="LASSO_SCRATCHPAD.md"
	_init_scratchpad "${scratchpad}" "${task}" "${LASSO_CHECKS[@]}"
	echo "lasso: scratchpad → ${PWD}/${scratchpad}"

	local iteration=0

	while [[ ${iteration} -lt ${max_iterations} ]]; do
		iteration=$((iteration + 1))
		echo ""
		echo "lasso: ── iteration ${iteration}/${max_iterations} ──────────────────────────"

		# Append iteration header to scratchpad
		printf '\n## Iteration %s\n\n' "${iteration}" >>"${scratchpad}"

		# Build prompt
		local prompt
		prompt=$(_build_prompt "${task}" "${LASSO_CONTEXT}" "${iteration}" "${scratchpad}")

		local claude_log="${run_dir}/iteration-${iteration}-claude.log"

		echo "lasso: invoking claude (timeout: ${timeout}s)"
		echo "lasso: claude log → ${claude_log}"

		# Invoke Claude Code in background so we can track PID for Ctrl-C cleanup
		# --output-format stream-json emits one JSON object per line in real-time;
		# tee saves the raw stream to the log file while _display_stream shows progress.
		# Unset CLAUDECODE so lasso can be invoked from within a Claude Code session.
		local sandbox_args=()
		local sandbox_env=()
		if [[ ${sandbox} == "true" ]]; then
			sandbox_args=(--settings "$(_sandbox_settings)")
			sandbox_env=(NO_PROXY="127.0.0.1,localhost")
		fi

		env -u CLAUDECODE "${sandbox_env[@]}" timeout "${timeout}" claude \
			--print \
			--verbose \
			--output-format stream-json \
			--dangerously-skip-permissions \
			--allowedTools "Bash,Edit,Read,Write,Glob,Grep" \
			"${sandbox_args[@]}" \
			-- "${prompt}" \
			2>&1 | tee "${claude_log}" | _display_stream &
		_CLAUDE_PID=$!
		if ! wait "${_CLAUDE_PID}"; then
			local exit_code=$?
			echo "lasso: claude exited with code ${exit_code}" >&2
			echo "lasso: see ${claude_log} for details" >&2
			# Don't abort — let checks surface the failure
		fi
		_CLAUDE_PID=""

		# Run checks if any are defined
		if [[ ${#LASSO_CHECKS[@]} -eq 0 ]]; then
			echo "lasso: no checks defined — done"
			exit 0
		fi

		local check_log="${run_dir}/iteration-${iteration}-checks.log"
		echo ""
		echo "lasso: running ${#LASSO_CHECKS[@]} check(s)..."

		local check_output
		if check_output=$(_run_checks "${LASSO_CHECKS[@]}" 2>&1); then
			echo "${check_output}" | tee "${check_log}"
			_append_check_results "${scratchpad}" "true" ""
			echo ""
			echo "lasso: all checks passed on iteration ${iteration}"
			echo "lasso: run complete — logs in ${run_dir}"
			exit 0
		else
			echo "${check_output}" | tee "${check_log}"
			_append_check_results "${scratchpad}" "false" "${check_output}"
			echo ""
			echo "lasso: checks failed, feeding back to Claude..."
		fi
	done

	echo ""
	echo "lasso: maximum iterations (${max_iterations}) reached without all checks passing" >&2
	echo "lasso: logs in ${run_dir}" >&2
	exit 1
}

# ── dispatch ──────────────────────────────────────────────────────────────────

if [[ $# -eq 0 ]]; then
	usage
	exit 1
fi

command="$1"
shift

case "${command}" in
up) cmd_up "$@" ;;
down) cmd_down "$@" ;;
status) cmd_status "$@" ;;
run) cmd_run "$@" ;;
help | --help | -h) usage ;;
*)
	echo "lasso: unknown command: ${command}" >&2
	usage >&2
	exit 1
	;;
esac
