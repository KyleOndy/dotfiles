# shellcheck shell=bash
# writeShellApplication provides the shebang and `set -euo pipefail`; this
# file is only the body (nix/pkgs/mlx-start/default.nix).
#
# Starts trex's local MLX model server (see nix/hosts/trex/home.nix) if it
# isn't already running. Doesn't wait for the model to finish loading --
# check with mlx-status, or just run search-mail/pi-overnight, which wait
# for it themselves.

readonly LABEL="org.ondy.mlx-openai-server"

launchctl kickstart -k "gui/$(id -u)/$LABEL"
echo "mlx-start: kickstarted $LABEL (check mlx-status for readiness)" >&2
