# shellcheck shell=bash
# writeShellApplication provides the shebang and `set -euo pipefail`; this
# file is only the body (nix/pkgs/mlx/default.nix).
#
# Controls trex's local MLX model server (see nix/hosts/trex/home.nix). Was
# three separate packages, mlx-start/mlx-stop/mlx-status, which between them
# carried three copies of the launchd label and two of the state probe.

readonly LABEL="org.ondy.mlx-openai-server"
readonly PORT=8770
readonly BASE_URL="http://127.0.0.1:$PORT"

# PyPI's mlx wheels, because nixpkgs builds mlx without Metal. Outside ~/.pi,
# which every alamode session can write: a .pth file dropped into
# site-packages would run unsandboxed in the server.
readonly VENV="$HOME/.local/state/mlx/venv"
readonly STAMP="$VENV/.requirements"
# Keyed on both: a collected python312 leaves the interpreter link dangling
# without changing the requirements.
readonly VENV_KEY="$REQUIREMENTS $PYTHON"

# Empty when the job is loaded but not running, and when launchctl cannot find
# it at all. Neither case is an error worth distinguishing here.
state() {
	launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null |
		awk '/state = /{print $3; exit}'
}

# Empty when the job is not running.
server_pid() {
	launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null |
		awk '$1 == "pid" && $2 == "=" {print $3; exit}'
}

ensure_venv() {
	if [ -x "$VENV/bin/python" ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$VENV_KEY" ]; then
		return 0
	fi
	# launchd starts the server through `mlx run`, so the job's own pid may
	# rebuild; any other running server would lose its venv underneath it.
	local pid
	pid=$(server_pid)
	if [ -n "$pid" ] && [ "$pid" != "$$" ]; then
		echo "mlx: the venv needs rebuilding, but the server (pid $pid) runs from it. Run 'mlx stop' first." >&2
		exit 1
	fi
	echo "mlx: building the venv, this runs once per requirements change" >&2
	rm -rf "$VENV"
	uv venv --quiet --python "$PYTHON" "$VENV" >&2
	VIRTUAL_ENV="$VENV" uv pip sync --quiet --require-hashes "$REQUIREMENTS" >&2
	printf '%s\n' "$VENV_KEY" >"$STAMP"
}

run() {
	ensure_venv
	# A leaked PYTHONPATH shadows the venv.
	unset PYTHONPATH
	exec "$VENV/bin/$1" "${@:2}"
}

start() {
	ensure_venv
	# Does not wait for the model to finish loading. Check with `mlx status`,
	# or just run search-mail, which waits for it itself.
	launchctl kickstart -k "gui/$(id -u)/$LABEL"
	echo "mlx: kickstarted $LABEL (check 'mlx status' for readiness)" >&2
}

stop() {
	# RunAtLoad and KeepAlive are both false, so this is durable: nothing
	# restarts the server until the next start or search-mail.
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

usage() {
	echo "usage: mlx [start|stop|status] | run PROGRAM [ARGS...]" >&2
	exit 2
}

case "${1-}" in
start) start ;;
stop) stop ;;
status | "") status ;;
run)
	[ $# -ge 2 ] || usage
	shift
	run "$@"
	;;
*) usage ;;
esac
