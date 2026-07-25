# shellcheck shell=bash
# writeShellApplication provides the shebang and `set -euo pipefail`; this
# file is only the body (nix/pkgs/mlx/default.nix).
#
# Controls trex's local MLX model server (see nix/hosts/trex/home.nix). Was
# three separate packages, mlx-start/mlx-stop/mlx-status, which between them
# carried three copies of the launchd label and two of the state probe.

readonly LABEL="org.ondy.mlx-openai-server"
readonly BASE_URL="http://127.0.0.1:8000"

# Empty when the job is loaded but not running, and when launchctl cannot find
# it at all. Neither case is an error worth distinguishing here.
state() {
	launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null |
		awk '/state = /{print $3; exit}'
}

start() {
	# Does not wait for the model to finish loading. Check with `mlx status`,
	# or just run search-mail/pi-overnight, which wait for it themselves.
	launchctl kickstart -k "gui/$(id -u)/$LABEL"
	echo "mlx: kickstarted $LABEL (check 'mlx status' for readiness)" >&2
}

stop() {
	# RunAtLoad and KeepAlive are both false, so this is durable: nothing
	# restarts the server until the next start, search-mail, or pi-overnight.
	# Frees the ~8GB of unified memory it holds resident.
	if [ "$(state)" != "running" ]; then
		echo "mlx: $LABEL is not running" >&2
		return 0
	fi

	launchctl kill SIGTERM "gui/$(id -u)/$LABEL"
	echo "mlx: stopped $LABEL" >&2
}

status() {
	# mlx-openai-server runs multi-model and on-demand
	# (nix/hosts/trex/mlx-models.yaml): every configured model shows up in
	# /v1/models as soon as the process is up, whether or not its weights are
	# loaded, and there is no public API for which one is resident. So this
	# reports what is registered, not what is warm. The first request against
	# a given model pays its load cost either way.
	if [ "$(state)" != "running" ]; then
		echo "stopped"
		return 0
	fi

	local models
	models="$(curl -fsS "$BASE_URL/v1/models" 2>/dev/null | jq -r '[.data[]?.id] | join(", ")')"
	if [ -n "$models" ]; then
		echo "running, registered (not necessarily loaded): $models"
	else
		echo "running: (not yet serving -- still starting up)"
	fi
}

case "${1-}" in
start) start ;;
stop) stop ;;
status | "") status ;;
*)
	echo "usage: mlx [start|stop|status]" >&2
	exit 2
	;;
esac
