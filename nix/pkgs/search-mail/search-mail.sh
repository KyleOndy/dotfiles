# shellcheck shell=bash
# writeShellApplication provides the shebang and `set -euo pipefail`; this
# file is only the body (nix/pkgs/search-mail/default.nix).
#
# Drives the `pi` coding agent against trex's local MLX model server (see
# nix/hosts/trex/home.nix) to search Kyle's email, so mail search stays fully
# private and offline -- no cloud model call. Trex-only: dino has the maildir
# but no local model server, and work-mac has neither, so this package is
# installed only on trex (nix/hosts/trex/configuration.nix). The cloud
# version this replaces lived at nix/pkgs/my-scripts/scripts/search-mail.
#
#   search-mail [question words...]

readonly instructions="You help Kyle search his email using notmuch (default \
configuration, maildir at ~/mail). Build queries with notmuch search syntax \
such as from:, to:, subject:, date:since..until, tag:inbox, and plain \
full-text terms. Use 'notmuch search' to find matching threads and \
'notmuch show' to read the messages. When you answer, cite the date, sender, \
and subject of the messages you drew from. Be concise and factual; if you \
cannot find an answer, say so plainly."

readonly LABEL="org.ondy.mlx-openai-server"
readonly BASE_URL="http://127.0.0.1:8000"
readonly MODEL="local/qwen3-14b"
readonly READY_TIMEOUT_S=60

# pi's strict sandbox makes $PWD writable, so cd'ing to $HOME (as the cloud
# version did) would make the whole home directory writable. ~/.pi is already
# allow-write by the wrapper (nix/pkgs/pi-wrapper/wrapper.sh), so run from a
# disposable subdirectory of it instead.
readonly workdir="$HOME/.pi/search-mail-cwd"
mkdir -p "$workdir"
cd "$workdir" || exit

server_ready() {
	curl -fsS -o /dev/null "$BASE_URL/v1/models"
}

# mlx-openai-server runs on-demand (RunAtLoad/KeepAlive both false), so warm
# it up if it's not already serving. Same pattern as pi-overnight
# (nix/pkgs/pi-overnight/pi-overnight.sh).
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
		echo "search-mail: local model server did not become ready within ${READY_TIMEOUT_S}s" >&2
		exit 1
	fi
fi

# --allow-read must come before --model/--append-system-prompt: the pi
# wrapper's arg parser only recognizes its own --allow-*/--web/--no-sandbox
# flags and stops at the first argument it doesn't recognize, passing
# everything from that point on straight through to the real `pi` binary
# unparsed (see nix/pkgs/pi-wrapper/wrapper.sh). Putting --model first would
# skip --allow-read parsing entirely.
#
# No --allowedTools equivalent is needed: granting read-only access to
# ~/mail (which covers the maildir and the Xapian db under ~/mail/.notmuch)
# and ~/.config/notmuch (notmuch's config) is enough for notmuch
# search/show/count/address to work, and pi's default-deny-write sandbox
# means any attempted `notmuch tag`/`notmuch new` is blocked at the OS level
# rather than relying on a tool allowlist.
args=(
	--allow-read "$HOME/mail"
	--allow-read "$HOME/.config/notmuch"
	--model "$MODEL"
	--append-system-prompt "$instructions"
)

# Any arguments become the initial query (joined into one prompt) and are
# auto-submitted; pi then stays interactive. With no arguments, land in an
# empty prompt with the notmuch context already loaded.
if [ "$#" -gt 0 ]; then
	args+=("$*")
fi

exec pi "${args[@]}"
