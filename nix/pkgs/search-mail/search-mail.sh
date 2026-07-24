# shellcheck shell=bash
# writeShellApplication provides the shebang and `set -euo pipefail`; this
# file is only the body (nix/pkgs/search-mail/default.nix).
#
# Drives the `pi` coding agent against trex's local MLX model server (see
# nix/hosts/trex/home.nix) to search Kyle's email, so mail search stays fully
# private and offline -- no cloud model call. Trex-only: it's the only host
# with both the maildir and a local model server (work-mac has neither), so
# this package is installed only on trex (nix/hosts/trex/configuration.nix).
# The cloud version this replaces lived at
# nix/pkgs/my-scripts/scripts/search-mail.
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
readonly SERVED_MODEL_NAME="${MODEL#*/}"
readonly READY_TIMEOUT_S=60

# pi's strict sandbox makes $PWD writable, so cd'ing to $HOME (as the cloud
# version did) would make the whole home directory writable. ~/.pi is already
# allow-write by the wrapper (nix/pkgs/pi-wrapper/wrapper.sh), so run from a
# disposable subdirectory of it instead.
readonly workdir="$HOME/.pi/search-mail-cwd"
mkdir -p "$workdir"
cd "$workdir" || exit

# Checks that the server is not just answering, but is actually serving
# $SERVED_MODEL_NAME. A bare "does anything answer on :8000" check isn't
# enough: mlx-openai-server is single-model, and if some other process (e.g.
# a stray manually-started instance on an older model) is already squatting
# on the port, launchctl kickstart can't bind the correct one, and every
# request would silently run against the wrong model until pi's completion
# call fails deep inside the sandbox with an opaque 404.
served_model_ready() {
	curl -fsS "$BASE_URL/v1/models" 2>/dev/null |
		jq -e --arg m "$SERVED_MODEL_NAME" '.data[]?.id == $m' >/dev/null 2>&1
}

# mlx-openai-server runs on-demand (RunAtLoad/KeepAlive both false), so warm
# it up if it's not already serving the right model. Same pattern as
# pi-overnight (nix/pkgs/pi-overnight/pi-overnight.sh).
if ! served_model_ready; then
	echo "Starting local model server ($LABEL)..." >&2
	launchctl kickstart -k "gui/$(id -u)/$LABEL"

	ready=false
	for _ in $(seq 1 "$READY_TIMEOUT_S"); do
		if served_model_ready; then
			ready=true
			break
		fi
		sleep 1
	done
	if [ "$ready" != true ]; then
		echo "search-mail: local model server did not start serving '$SERVED_MODEL_NAME' within ${READY_TIMEOUT_S}s." >&2
		if curl -fsS -o /dev/null "$BASE_URL/v1/models" 2>/dev/null; then
			echo "search-mail: something is answering on $BASE_URL, but not with '$SERVED_MODEL_NAME'." >&2
			echo "search-mail: a stray process may be holding port 8000 -- check 'lsof -i :8000' and 'launchctl print gui/$(id -u)/$LABEL'." >&2
		fi
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

# Pins pi's changelog cursor past any real version, so its "What's New"
# banner (which can be several screens of release notes) never prints for
# this scripted invocation -- it should read like a plain CLI tool, not an
# interactive coding session. ~/.pi/agent/settings.json isn't nix-managed
# (nix/modules/hm_modules/dev/pi-coding-agent/default.nix only writes it when
# settingsJson is configured, which it isn't on trex), so mutating it here is
# safe. This is shared with interactive `pi` sessions, so it also means Kyle
# won't see the same changelog a second time interactively after search-mail
# has already pinned past it -- an acceptable tradeoff against dumping
# release notes into what should look like a plain search tool. Best effort:
# a failure here shouldn't block mail search.
pin_changelog_cursor() {
	local settings="$HOME/.pi/agent/settings.json" tmp current
	mkdir -p "$(dirname "$settings")"
	current="{}"
	if [ -f "$settings" ]; then
		current="$(cat "$settings")"
	fi
	tmp="$(mktemp "${settings}.XXXXXX")"
	echo "$current" | jq --arg v "9999.0.0" '.lastChangelogVersion = $v' >"$tmp"
	mv "$tmp" "$settings"
}
pin_changelog_cursor || echo "search-mail: warning: could not pin pi's changelog cursor, continuing anyway" >&2

exec pi "${args[@]}"
