# shellcheck shell=bash
# writeShellApplication provides the shebang and `set -euo pipefail`; this
# file is only the body (nix/pkgs/mlx-stop/default.nix).
#
# Stops trex's local MLX model server (see nix/hosts/trex/home.nix), freeing
# the ~8GB of unified memory it holds resident. RunAtLoad/KeepAlive are both
# false, so this is durable -- nothing restarts it until mlx-start,
# search-mail, or pi-overnight next kickstart it.

readonly LABEL="org.ondy.mlx-openai-server"

state="$(launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null | awk '/state = /{print $3; exit}')"
if [ "$state" != "running" ]; then
	echo "mlx-stop: $LABEL is not running" >&2
	exit 0
fi

launchctl kill SIGTERM "gui/$(id -u)/$LABEL"
echo "mlx-stop: stopped $LABEL" >&2
