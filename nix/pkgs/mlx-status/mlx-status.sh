# shellcheck shell=bash
# writeShellApplication provides the shebang and `set -euo pipefail`; this
# file is only the body (nix/pkgs/mlx-status/default.nix).
#
# Reports whether trex's local MLX model server (see nix/hosts/trex/home.nix)
# is running and which models it has registered.
#
# mlx-openai-server runs multi-model, on-demand (nix/hosts/trex/mlx-models.
# yaml): every configured model shows up in /v1/models as soon as the
# process is up, regardless of whether its weights are actually loaded into
# memory yet, and there is no public API to tell which one(s) are currently
# resident. So this can only report what's registered, not what's warm --
# the first request against a given model pays its load cost either way.

readonly LABEL="org.ondy.mlx-openai-server"
readonly BASE_URL="http://127.0.0.1:8000"

state="$(launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null | awk '/state = /{print $3; exit}')"

if [ "$state" != "running" ]; then
	echo "stopped"
	exit 0
fi

models="$(curl -fsS "$BASE_URL/v1/models" 2>/dev/null | jq -r '[.data[]?.id] | join(", ")')"
if [ -n "$models" ]; then
	echo "running, registered (not necessarily loaded): $models"
else
	echo "running: (not yet serving -- still starting up)"
fi
