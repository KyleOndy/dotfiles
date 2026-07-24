# shellcheck shell=bash
# writeShellApplication provides the shebang and `set -euo pipefail`; this
# file is only the body (nix/pkgs/mlx-status/default.nix).
#
# Reports whether trex's local MLX model server (see nix/hosts/trex/home.nix)
# is running and which model it's serving.

readonly LABEL="org.ondy.mlx-openai-server"
readonly BASE_URL="http://127.0.0.1:8000"

state="$(launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null | awk '/state = /{print $3; exit}')"

if [ "$state" != "running" ]; then
	echo "stopped"
	exit 0
fi

model="$(curl -fsS "$BASE_URL/v1/models" 2>/dev/null | jq -r '.data[0].id // empty')"
if [ -n "$model" ]; then
	echo "running: $model"
else
	echo "running: (not yet serving -- still loading)"
fi
