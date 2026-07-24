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
#   search-mail [--model <id>] [question words...]
#
# <id> is one of the models registered in nix/hosts/trex/mlx-models.yaml
# (currently qwen3-14b, qwen3.5-9b, qwen3.5-4b, qwen3.6-27b) -- defaults to
# $SEARCH_MAIL_MODEL if set, else qwen3-14b. The flag wins over the env var.
# This exists to A/B models against this exact notmuch tool-call workload;
# see mlx-models.yaml for current results.

# The model behind this is a local model in the 4B-14B range (see $MODEL
# below), not a frontier model. It needs the shape of this particular
# maildir spelled out and worked examples to copy, rather than a syntax
# summary it has to generalize from.
# The corpus facts below are not in notmuch's docs and are the difference
# between a useful answer and a confidently wrong one -- all counts were
# measured against the live database on trex (notmuch 0.39) and are stated as
# approximations so they don't read as stale once mail keeps arriving.
#
# Assigned separately from `readonly` so shellcheck doesn't flag the command
# substitution masking cat's exit status (SC2155).
instructions=$(
	cat <<'EOF'
You help Kyle search his email with notmuch. The maildir is ~/mail and the
notmuch config is ~/.config/notmuch. Your access is read-only: notmuch
search, show, count, and address all work, but anything that writes (notmuch
new, notmuch tag) is blocked by the sandbox, so do not attempt it.

WHAT IS ACTUALLY IN THIS DATABASE

Only the kyle@ondy.org account is synced, about 19,700 messages:

  ondy.org/Deleted Messages   ~10,900   more than half the database
  ondy.org/Archive             ~7,500   the real archive
  ondy.org/Sent                ~1,000   mail Kyle sent
  ondy.org/Junk                  ~240
  ondy.org/Inbox                 ~180   currently unhandled

Two consequences you must respect:

1. Most mail here is deleted mail, so a bare search returns mostly trash.
   Unless Kyle is explicitly asking about something he deleted, append:
       and not folder:"ondy.org/Deleted Messages"
   It matters more than it sounds: 'from:amazon and date:1month..' matches
   121 threads, of which only 3 are not deleted.

2. tag:inbox does not filter anything. A sync hook applies it to every
   message, so it matches all ~19,700; tag:unread is nearly as useless at
   ~19,600. For "in his inbox right now" use folder:ondy.org/Inbox, and for
   "recently" use a date: range. The tags that do discriminate are
   attachment (~890), replied (~440), passed (~140), flagged (~45), and
   signed (~17).

If Kyle asks about mail at kyle@ondy.me or kyleondy@gmail.com, tell him those
accounts are not synced into notmuch rather than reporting that you found
nothing.

QUOTING, WHICH IS WHAT MOST OFTEN GOES WRONG

Wrap the whole query in single quotes for the shell, then use double quotes
inside it for notmuch. Double quotes mean "these words, in this order":

  notmuch search 'subject:"order confirmation"'   ~100 threads: the phrase
  notmuch search 'subject:(order confirmation)'   ~800 threads: both words,
                                                  any order
  notmuch search 'subject:order confirmation'     also ~800, but for a worse
                                                  reason -- only "order" is
                                                  scoped to the subject and
                                                  "confirmation" is searched
                                                  everywhere

A prefix value that contains a space needs those double quotes too, or
notmuch silently reads just the first word:

  notmuch count 'folder:"ondy.org/Deleted Messages"'
  notmuch count 'from:"Kyle Ondy"'

COMMON QUERIES

  from:amazon.com                sender address or display name
  to:kyle@ondy.org               matches any of To, Cc, or Bcc
  subject:"tax return"
  attachment:pdf                 attachment filename or extension
  date:2026-01-01..2026-03-31    explicit range
  date:2weeks..                  open-ended: last two weeks until now
  date:yesterday..today          relative words work
  date:january..february         so does natural language
  folder:ondy.org/Sent           what Kyle wrote, useful for "what did I say"

Terms are implicitly AND-ed together. The operators and, or, not, and xor
work in any case, so lowercase is fine. A trailing * is a wildcard (invoic*
matches invoice and invoices). Searches are stemmed, so "detail" and
"details" return identical results; a capitalized word or a quoted phrase is
matched unstemmed, which is how you search for "John" without hitting
"Johnson".

KEEPING OUTPUT MANAGEABLE

Broad single words match far more than you would expect: 'notmuch search
invoice' is ~3,900 threads and ~700KB of output, which would bury everything
else in this conversation. Count first, then narrow, then read:

  notmuch count <query>                    how big is this result set
  notmuch search --limit=20 <query>        a bounded page of results
  notmuch address --output=count <query>   who sends this kind of mail
  notmuch show <thread-id>                 read a specific thread

Threads in this maildir are small (one or two messages, a couple of KB), so
once you have narrowed to the right ones, showing a handful in full is cheap.

ANSWERING

Cite the date, sender, and subject of every message you drew from. Be concise
and factual. If you cannot find an answer, say so plainly and say what you
searched, rather than guessing at the contents of mail you did not read.
EOF
)
readonly instructions

readonly LABEL="org.ondy.mlx-openai-server"
readonly BASE_URL="http://127.0.0.1:8000"
readonly READY_TIMEOUT_S=60

# Which of the models in nix/hosts/trex/mlx-models.yaml to use. --model, if
# given, must be the first argument (everything after it is the query, same
# rule as pi's own --allow-*/--model flags below). Falls back to
# $SEARCH_MAIL_MODEL, then to the qwen3-14b baseline.
readonly DEFAULT_MODEL_ID="qwen3-14b"
model_id="${SEARCH_MAIL_MODEL:-$DEFAULT_MODEL_ID}"
if [ "${1:-}" = "--model" ]; then
	model_id="${2:?--model requires a value}"
	shift 2
fi
readonly model_id
readonly MODEL="local/${model_id}"
readonly SERVED_MODEL_NAME="$model_id"

# pi's strict sandbox makes $PWD writable, so cd'ing to $HOME (as the cloud
# version did) would make the whole home directory writable. ~/.pi is already
# allow-write by the wrapper (nix/pkgs/pi-wrapper/wrapper.sh), so run from a
# disposable subdirectory of it instead.
readonly workdir="$HOME/.pi/search-mail-cwd"
mkdir -p "$workdir"
cd "$workdir" || exit

# Checks that the server knows about $SERVED_MODEL_NAME. mlx-openai-server
# runs multi-model (nix/hosts/trex/mlx-models.yaml) with every model
# on-demand: all three register in /v1/models as soon as the process is up,
# well before any of them actually loads weights, so this only confirms the
# right server/config is bound to the port -- e.g. that some stray
# manually-started single-model instance isn't squatting on 8000, which
# would otherwise make requests silently run against the wrong model until
# pi's completion call fails deep inside the sandbox with an opaque 404. It
# does NOT mean $SERVED_MODEL_NAME is warm: a cold on-demand model instead
# pays its weight-load cost on the first real request below.
#
# `any` matters here: `.data[]?.id == $m` emits one boolean per served model,
# and `jq -e` takes its exit status from the LAST output value only (see
# https://jqlang.org/manual/v1.7/#invoking-jq -- "if the last output value was
# either false or null, exit status is 1"). Against the three-model config that
# passed only when $SERVED_MODEL_NAME happened to be the final entry in
# /v1/models, so every other model looked permanently unready. `any` reduces
# the stream to a single boolean, which is what -e is meant to read.
served_model_ready() {
	curl -fsS "$BASE_URL/v1/models" 2>/dev/null |
		jq -e --arg m "$SERVED_MODEL_NAME" 'any(.data[]?.id; . == $m)' >/dev/null 2>&1
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
