# shellcheck shell=bash
# A stand-in for `pi --mode rpc`, for nix/checks/pi-delegate.nix. It records
# its arguments and every command it reads in $PI_STUB_DIR, and acts out each
# prompt by the prompt's first word.
set -euo pipefail
out="${PI_STUB_DIR}"
printf '%s\n' "$@" >"${out}/args"
echo "$$" >"${out}/pi.pid"
turn=0 running=false dialog=false

ev() {
	printf '%s\n' "$1"
	sleep 0.05
}

finish() {
	ev '{"type":"tool_execution_start","toolName":"read","args":{"path":"a.nix"}}'
	ev '{"type":"message_end","message":{"role":"assistant","usage":{"totalTokens":10,"cost":{"total":0.25}}}}'
	ev '{"type":"tool_execution_start","toolName":"grep","args":{"pattern":"x"}}'
	ev '{"type":"message_end","message":{"role":"assistant","usage":{"totalTokens":20,"cost":{"total":0.5}}}}'
	ev "$(jq -nc --arg t "the answer ${turn}" \
		'{type: "agent_end", messages: [{role: "assistant", stopReason: "stop", content: [{type: "text", text: $t}]}]}')"
	ev '{"type":"agent_settled"}'
	running=false
}

ev '{"type":"session"}'
while IFS= read -r cmd; do
	printf '%s\n' "${cmd}" >>"${out}/cmds"
	case "$(jq -r .type <<<"${cmd}")" in
	prompt)
		id="$(jq -r '.id // ""' <<<"${cmd}")"
		word="$(jq -r '.message | rtrimstr("\n") | split(" ")[0]' <<<"${cmd}")"
		if [[ ${word} == reject ]]; then
			jq -nc --arg id "${id}" '{id: $id, type: "response", command: "prompt", success: false, error: "nope"}'
			continue
		fi
		jq -nc --arg id "${id}" '{id: $id, type: "response", command: "prompt", success: true}'
		case "${word}" in
		noagent) exit 0 ;;
		crash)
			echo boom >&2
			exit 3
			;;
		hang | die) exec sleep 600 ;;
		esac
		turn=$((turn + 1))
		if [[ ${running} == true ]]; then
			# A steer joins the turn in progress.
			finish
			continue
		fi
		running=true
		ev '{"type":"agent_start"}'
		case "${word}" in
		error)
			ev '{"type":"auto_retry_start","attempt":1,"maxAttempts":2,"errorMessage":"503: no endpoints"}'
			ev '{"type":"agent_end","messages":[{"role":"assistant","stopReason":"error","errorMessage":"503: no endpoints","content":[]}]}'
			ev '{"type":"agent_settled"}'
			running=false
			;;
		# Settles only when steered or aborted.
		slow) ;;
		ui)
			ev '{"type":"extension_ui_request","id":"d1","method":"confirm","title":"Allow?"}'
			dialog=true
			;;
		write)
			echo hi >made.txt
			finish
			;;
		*) finish ;;
		esac
		;;
	extension_ui_response)
		if [[ ${dialog} == true ]]; then
			dialog=false
			finish
		fi
		;;
	abort)
		if [[ ${running} == true ]]; then
			ev '{"type":"agent_end","messages":[{"role":"assistant","stopReason":"aborted","content":[]}]}'
			ev '{"type":"agent_settled"}'
			running=false
		fi
		ev '{"type":"response","command":"abort","success":true}'
		;;
	esac
done
