# shellcheck shell=bash
# writeShellApplication provides the shebang and `set -euo pipefail`; this
# file is only the body (nix/pkgs/mcloud-pins/default.nix), which also sets
# GREEN_PNG to the known image: a 64x64 PNG, every pixel #00a000, generated
# at build time.
#
# Checks that every mcloud model this machine registers in models.json or
# names in a seat is actually served, answers, and sees an image when its
# catalog entry says it does.
#
#   mcloud-pins            a table of every pin, then each failure with its fix
#   mcloud-pins --deploy   the same checks, run by `make deploy-*` after every
#                          switch. Its output lands in deploy logs and in the
#                          transcripts of agents that deploy, so it names no
#                          model: a failure names the seat vars pointing at
#                          the model and its position in the catalog. One
#                          line on success.
#
# The key is MCLOUD_API_KEY, or else whatever MCLOUD_API_KEY_COMMAND prints,
# which each host sets to its own secret store. Every failure says what is
# wrong, where it is configured and what to change, naming the sops file
# `pi-seats source` prints for this host.
#
# Two failures this catches, both of which shipped, and both of which fail
# silently at runtime rather than loudly:
#
#   - A pinned id the endpoint does not serve, which returns 404. advisor.ts
#     reads an empty reply as no verdict, so the watchdog simply goes quiet.
#   - A listed id that does not answer: it appears in `GET /v1/models` and
#     returns 503 on every completion, so listing membership alone proves
#     nothing. Each id gets a one-token completion.
#
# The capability check: each id that answers and whose catalog entry has
# "image" in input gets one more completion, carrying GREEN_PNG and asking
# for its color, which passes when the reply says green. Knowing the image
# makes the reply checkable, since an endpoint that drops image parts still
# answers 200, with a guess. It sends max_tokens 1024 and no reasoning
# parameter, so an empty reply most likely means the model reasoned through
# the whole budget.
#
# Sources checked, so a pin in either is covered:
#   ~/.pi/agent/models.json   the mcloud provider's models, what pi can select
#   pi-seats list             every seat in the host's seats file whose
#                             provider is mcloud, with the provider prefix and
#                             any :level suffix stripped. Skipped on a host
#                             without pi-seats.
#
# The live check is not a flake check: it needs the network and a
# credential, and `nix flake check` has neither (nix/checks/mcloud-pins.nix
# runs this against a stub endpoint). Not a models.json generator either.
# `GET /v1/models` returns only id/object/created/owned_by, so contextWindow,
# maxTokens, cost, thinkingLevelMap and the modality list, which is
# everything deciding how pi drives a model, would have to be invented
# rather than fetched. The pi module owns that file declaratively and
# overwrites it on every activation.

: "${GREEN_PNG:?path to the known image}"
readonly GREEN_PNG
readonly PROMPT="What color fills this image? Reply with one lowercase word."

case "$#:${1:-}" in
0:) DEPLOY="" ;;
1:--deploy) DEPLOY=1 ;;
*)
	echo "usage: mcloud-pins [--deploy]" >&2
	exit 2
	;;
esac
readonly DEPLOY

SOPS_FILE="$(pi-seats source 2>/dev/null || true)"
[ -n "$SOPS_FILE" ] || SOPS_FILE="this host's sops file"
readonly IN_SOPS="in $SOPS_FILE"

# die <what> <fix>: a failure before any model is checked.
die() {
	printf 'mcloud-pins: %s\n  fix: %s\n' "$1" "$2" >&2
	exit 2
}

plural() {
	if [ "$1" = 1 ]; then echo "1 $2"; else echo "$1 $2s"; fi
}

# The key goes to whatever baseUrl this file names, and every sandboxed pi
# session can write ~/.pi, so the link must be home-manager's. Only the first
# hop is checked: that store link is an mkOutOfStoreSymlink on to
# /run/secrets/pi_models_json, which sops-nix writes at activation.
MODELS_JSON="$(readlink "$HOME/.pi/agent/models.json" 2>/dev/null || true)"
readonly MODELS_JSON
case "$MODELS_JSON" in
/nix/store/*) ;;
*)
	if [ -n "$MODELS_JSON" ]; then
		state="a link to $MODELS_JSON"
	elif [ -e "$HOME/.pi/agent/models.json" ]; then
		state="a plain file"
	else
		state="missing"
	fi
	die "$HOME/.pi/agent/models.json is $state, not a link into /nix/store, so home-manager did not write it and its baseUrl is not trusted with the key" \
		"set hmFoundry.dev.pi-coding-agent.modelsJsonFile (or modelsJson) for this host and deploy, after moving aside anything else at that path"
	;;
esac

jq empty "$MODELS_JSON" 2>/dev/null ||
	die "$HOME/.pi/agent/models.json links to $MODELS_JSON, which is not readable JSON" \
		"add pi_models_json, holding the catalog as JSON, $IN_SOPS and deploy, so sops-nix writes the file it points at"

# The endpoint belongs with the provider definition: this repo names no model
# ids and no base URLs, both arrive in models.json from the host's sops secret.
BASE_URL="$(jq -r '(.providers.mcloud.baseUrl)? // empty' "$MODELS_JSON")"
readonly BASE_URL
[ -n "$BASE_URL" ] ||
	die "pi_models_json has no providers.mcloud.baseUrl, so there is no endpoint to check" \
		"set providers.mcloud.baseUrl in pi_models_json $IN_SOPS"

if [ -z "${MCLOUD_API_KEY:-}" ]; then
	[ -n "${MCLOUD_API_KEY_COMMAND:-}" ] ||
		die "no mcloud key: MCLOUD_API_KEY and MCLOUD_API_KEY_COMMAND are both unset" \
			"set MCLOUD_API_KEY_COMMAND to a command that prints the key (home.sessionVariables in this host's home.nix), or open a new shell if a deploy set it after this one started"
	rc=0
	MCLOUD_API_KEY="$(sh -c "$MCLOUD_API_KEY_COMMAND")" || rc=$?
	[ -n "$MCLOUD_API_KEY" ] ||
		die "MCLOUD_API_KEY_COMMAND printed no key (exit $rc)" \
			"run sh -c \"\$MCLOUD_API_KEY_COMMAND\" by hand and fix what it reports, or point MCLOUD_API_KEY_COMMAND (home.sessionVariables in this host's home.nix) at the key's real location"
fi

# api <seconds> <path> [json]: the response body, then the HTTP status on a
# line of its own, 000 when nothing answered. The key and the body reach curl
# through a file descriptor and stdin rather than its argv, which any user can
# read with ps.
api() {
	local args=(-s --max-time "$1" -w '\n%{http_code}')
	if [ $# -gt 2 ]; then
		args+=(-H "Content-Type: application/json" --data-binary @-)
	fi
	curl "${args[@]}" -H @<(printf 'Authorization: Bearer %s\n' "$MCLOUD_API_KEY") \
		"$BASE_URL/$2" <<<"${3:-}" || true
}

resp="$(api 30 models)"
code="${resp##*$'\n'}"
case "$code" in
200) ;;
000)
	die "GET /models at the mcloud baseUrl got no answer within 30s" \
		"check the network, then providers.mcloud.baseUrl in pi_models_json $IN_SOPS"
	;;
401 | 403)
	die "GET /models answered HTTP $code, so the endpoint refuses the key" \
		"check the key MCLOUD_API_KEY_COMMAND prints (or MCLOUD_API_KEY, which wins when set)"
	;;
404)
	die "GET /models answered HTTP 404, so the baseUrl is not an OpenAI-compatible API root" \
		"correct providers.mcloud.baseUrl in pi_models_json $IN_SOPS"
	;;
*)
	die "GET /models answered HTTP $code" \
		"rerun mcloud-pins; if it fails the same way, check providers.mcloud.baseUrl in pi_models_json $IN_SOPS"
	;;
esac
served="$(jq -r '.data[]?.id // empty' <<<"${resp%$'\n'*}" 2>/dev/null | sort -u || true)"
[ -n "$served" ] ||
	die "GET /models answered 200 with no model ids" \
		"check that providers.mcloud.baseUrl in pi_models_json $IN_SOPS is the mcloud API root"

# Per id: the seat vars naming it, its catalog positions, whether its entry
# declares image input.
declare -A seat_vars=() entries=() image=()
while IFS=$'\t' read -r n id sees; do
	entries[$id]+="${entries[$id]:+, }pi_models_json providers.mcloud.models[$n]"
	if [ "$sees" = true ]; then image[$id]=1; fi
done < <(jq -r '(.providers.mcloud.models)? // [] | to_entries[]
	| select(.value.id | type == "string" and . != "")
	| [.key, .value.id, ((.value.input // []) | any(. == "image"))] | @tsv' "$MODELS_JSON")
if command -v pi-seats >/dev/null; then
	seats="$(pi-seats list)" ||
		die "pi-seats list failed, so no seat was checked" \
			"run pi-seats check --deploy and fix what it reports"
	while IFS=$'\t' read -r var value; do
		[[ $value == mcloud/* ]] || continue
		id="${value#mcloud/}"
		case "${id##*:}" in
		off | minimal | low | medium | high | xhigh | max) id="${id%:*}" ;;
		esac
		seat_vars[$id]+="${seat_vars[$id]:+, }$var"
	done <<<"$seats"
fi
[ ${#entries[@]} -gt 0 ] || [ ${#seat_vars[@]} -gt 0 ] ||
	die "nothing names an mcloud model: pi_models_json has no providers.mcloud.models and no seat starts with mcloud/" \
		"list this host's models in pi_models_json providers.mcloud.models and point PI_SESSION_MODEL at one of them, $IN_SOPS"
ids="$(printf '%s\n' "${!entries[@]}" "${!seat_vars[@]}" | sort -u)"

IMAGE_URL="data:image/png;base64,$(base64 -w0 "$GREEN_PNG")"
readonly IMAGE_URL

report=""
problems=0
# problem <what> <fix>, about the id the loop is on.
problem() {
	report+="mcloud-pins: $subject: $1"$'\n'"  fix: $2"$'\n'
	problems=$((problems + 1))
}

npins=0
seen=0
[ -n "$DEPLOY" ] || printf '%-30s %-8s %-6s %-6s %s\n' MODEL LISTED PROBE IMAGE 'PINNED IN'
while read -r id; do
	npins=$((npins + 1))
	vars="${seat_vars[$id]:-}"
	at="${entries[$id]:-}"
	where="$vars${vars:+${at:+, }}$at"
	if [ -n "$DEPLOY" ]; then subject="$where"; else subject="$id ($where)"; fi
	listed=NO
	probe=skip
	sight=-
	[ -z "${image[$id]:-}" ] || sight=skip

	if [ -z "$at" ]; then
		problem "a seat names this mcloud model, but pi_models_json has no entry for it, so pi cannot select it" \
			"add an entry for it to pi_models_json providers.mcloud.models, or point $vars at a catalogued model, $IN_SOPS"
	fi

	if printf '%s\n' "$served" | grep -qxF -- "$id"; then
		listed=yes
		req="$(jq -nc --arg model "$id" '{model: $model, max_tokens: 1, messages: [{role: "user", content: "hi"}]}')"
		resp="$(api 60 chat/completions "$req")"
		probe="${resp##*$'\n'}"
		# 429 came from the model's own endpoint, so the id routes and the
		# pin is sound; the throttle is this script's own fault for asking.
		case "$probe" in
		200 | 429) ;;
		000)
			problem "a one-token completion got no answer within 60s" \
				"rerun mcloud-pins; if it fails the same way, replace the model in $where, $IN_SOPS"
			;;
		503)
			problem "listed, but a one-token completion answers HTTP 503, so nothing serves it" \
				"replace the model in $where, $IN_SOPS, or rerun mcloud-pins once the endpoint serves it"
			;;
		*)
			problem "listed, but a one-token completion answers HTTP $probe" \
				"replace the model in $where, $IN_SOPS"
			;;
		esac
	else
		problem "the endpoint does not list this model" \
			"correct the id, or pick a model the endpoint lists, in $where, $IN_SOPS"
	fi

	if [ "$sight" = skip ] && { [ "$probe" = 200 ] || [ "$probe" = 429 ]; }; then
		req="$(jq -nc --arg model "$id" --arg text "$PROMPT" --arg url "$IMAGE_URL" '{model: $model,
			max_tokens: 1024, messages: [{role: "user", content: [{type: "text", text: $text},
			{type: "image_url", image_url: {url: $url}}]}]}')"
		resp="$(api 120 chat/completions "$req")"
		code="${resp##*$'\n'}"
		body="${resp%$'\n'*}"
		reply="$(jq -r '.choices[0].message.content // empty' <<<"$body" 2>/dev/null || true)"
		fix="remove \"image\" from input in $at${vars:+, or point $vars at a model that sees images}, $IN_SOPS"
		sight=FAIL
		if [ "$code" != 200 ]; then
			said="$(jq -r '.error.message? // .message? // empty' <<<"$body" 2>/dev/null || true)"
			said="${said//[[:space:]]/ }"
			said="${said:+ (the endpoint said: ${said:0:200})}"
			[ -z "$DEPLOY" ] || said=""
			case "$code" in
			000)
				problem "the image check got no answer within 120s" "rerun mcloud-pins; if it fails the same way, $fix"
				;;
			429 | 5??)
				problem "the image check answers HTTP $code$said" "rerun mcloud-pins; if it fails the same way, $fix"
				;;
			*)
				problem "the image check answers HTTP $code$said, so the endpoint refuses the image or the request" "$fix"
				;;
			esac
		elif [ -z "$reply" ]; then
			finish="$(jq -r '.choices[0].finish_reason // empty' <<<"$body" 2>/dev/null || true)"
			problem "the image check answered 200 with no text${finish:+ (finish_reason $finish)}, probably all 1024 tokens spent reasoning" \
				"a model that cannot name one color in 1024 tokens starves an image seat: $fix"
		elif ! grep -qiw green <<<"$reply"; then
			said="${reply//[[:space:]]/ }"
			said=" (it said: ${said:0:80})"
			[ -z "$DEPLOY" ] || said=""
			problem "the image check's reply does not name green$said, so the endpoint drops the image or the model cannot see it" "$fix"
		else
			sight=ok
			seen=$((seen + 1))
		fi
	fi

	[ -n "$DEPLOY" ] || printf '%-30s %-8s %-6s %-6s %s\n' "$id" "$listed" "$probe" "$sight" "$where"
done <<<"$ids"

# Served but nothing points at it. Not a failure, just the other half of the
# picture when picking a model.
if [ -z "$DEPLOY" ]; then
	unpinned="$(comm -23 <(printf '%s\n' "$served") <(printf '%s\n' "$ids") | paste -sd' ' -)"
	if [ -n "$unpinned" ]; then printf '\nserved, unpinned: %s\n' "$unpinned"; fi
fi

if [ "$problems" -ne 0 ]; then
	[ -n "$DEPLOY" ] || echo
	printf '%s' "$report" >&2
	echo "mcloud-pins: $(plural "$problems" problem) across $(plural "$npins" pin), each with its fix above" >&2
	exit 1
fi
if [ ${#image[@]} -eq 0 ]; then
	images="no entry declares image input"
else
	images="$(plural "$seen" "image check") passed"
fi
[ -n "$DEPLOY" ] || echo
echo "mcloud-pins: $(plural "$npins" pin) served and answering, $images"
