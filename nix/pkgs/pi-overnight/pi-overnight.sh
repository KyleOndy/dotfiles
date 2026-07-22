# shellcheck shell=bash
# writeShellApplication provides the shebang and `set -euo pipefail`; this
# file is only the body (nix/pkgs/pi-overnight/default.nix).
#
# Thin driver for unattended overnight pi runs against trex's local MLX
# model (see nix/hosts/trex/home.nix). Makes sure the model server is warm,
# then runs one pi agent loop to completion, logging the full JSON event
# stream so you can review what happened in the morning.
#
#   pi-overnight <task description...>
#
# Not a supervisor: one `pi --mode json` call runs pi's own agent loop
# until it stops on its own. No max-turns/retry logic -- if you need that,
# add it later once you know what actually goes wrong overnight.

readonly LABEL="org.ondy.mlx-openai-server"
readonly BASE_URL="http://127.0.0.1:8000"
readonly LOCAL_MODEL="local/qwen3-14b"
readonly LOG_DIR="$HOME/.pi/overnight/logs"
readonly READY_TIMEOUT_S=60

usage() {
	cat >&2 <<EOF
Usage: pi-overnight <task description...>

Runs pi unattended against the local model ($LOCAL_MODEL), logging the
full JSON event stream under $LOG_DIR.
EOF
	exit 1
}

[ $# -ge 1 ] || usage

server_ready() {
	curl -fsS -o /dev/null "$BASE_URL/v1/models"
}

if ! server_ready 2>/dev/null; then
	echo "Starting local model server ($LABEL)..." >&2
	launchctl kickstart -k "gui/$(id -u)/$LABEL"

	ready=false
	for _ in $(seq 1 "$READY_TIMEOUT_S"); do
		if server_ready 2>/dev/null; then
			ready=true
			break
		fi
		sleep 1
	done
	if [ "$ready" != true ]; then
		echo "local model server did not become ready within ${READY_TIMEOUT_S}s" >&2
		exit 1
	fi
fi

mkdir -p "$LOG_DIR"
log_file="$LOG_DIR/$(date +%Y%m%d-%H%M%S).jsonl"
echo "Logging to $log_file" >&2

pi --model "$LOCAL_MODEL" --mode json "$*" | tee "$log_file"
