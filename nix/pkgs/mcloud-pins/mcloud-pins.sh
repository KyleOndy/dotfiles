# shellcheck shell=bash
# writeShellApplication provides the shebang and `set -euo pipefail`; this
# file is only the body (nix/pkgs/mcloud-pins/default.nix), which also sets
# GREEN_PNG to the known image: a 64x64 PNG, every pixel #00a000, generated
# at build time.
#
# Checks that every mcloud model this machine registers in models.json or
# names in a seat is actually served, answers, and can do what its catalog
# entry and its seats say it can.
#
#   mcloud-pins            a table of every pin, then each failure with its fix
#   mcloud-pins --deploy   the same checks, run by `make deploy-*` after every
#                          switch. Its output lands in deploy logs and in the
#                          transcripts of agents that deploy, so it names no
#                          model: a failure names the seat vars pointing at
#                          the model and its position in the catalog. One
#                          line on success.
#   mcloud-pins --context  the same checks plus the context check, which
#                          costs about a million prompt tokens per model at
#                          today's windows, so nothing runs it unasked
#
# The key is MCLOUD_API_KEY, or else what MCLOUD_API_KEY_COMMAND prints,
# which defaults to the keyCommand this host built mcloud-pins with, reading
# its own secret store. Every failure says what is
# wrong, where it is configured and what to change, naming the sops file
# `alamode-seats source` prints for this host. A warning is a check whose answer
# could not be read either way; it does not fail the run.
#
# Two failures this catches, both of which shipped, and both of which fail
# silently at runtime rather than loudly:
#
#   - A pinned id the endpoint does not serve, which returns 404. advisor.ts
#     reads an empty reply as no verdict, so the watchdog simply goes quiet.
#   - A listed id that does not answer: it appears in `GET /v1/models` and
#     returns 503 on every completion, so listing membership alone proves
#     nothing. Each id gets a one-token completion, retried once on a 401,
#     a 403, a 5xx or no answer.
#
# The capability checks run on each id that answers and has a catalog entry.
# Every request carries the token field the engine sends: max_completion_tokens,
# unless the entry's compat.maxTokensField is max_tokens, since pi 1.0.0
# detects max_tokens only for a fixed list of vendors and mcloud is not on
# it. Each check asks something with a known answer, so the reply is
# checkable rather than merely present.
#
#   image      entries with "image" in input: GREEN_PNG, asking its color,
#              passes when the reply says green. An endpoint that drops image
#              parts still answers 200, with a guess. 1024 tokens, no
#              reasoning parameter.
#   reasoning  each level a seat names: a three-step sum with 4096 tokens and
#              the reasoning_effort the engine would send for that seat
#              below). Above off it passes on reasoning tokens or reasoning
#              text, fails when the endpoint reports none, and warns when it
#              reports nothing either way. At off any reasoning fails. An
#              empty or cut-off reply fails, a wrong sum warns.
#   tools      ids behind a seat whose consumer gives the model tools (the
#              session, spawn, delegate and agent seats): one get_weather
#              function, which the reply has to call for Paris.
#   context    --context only, entries with contextWindow: a prompt of 90% of
#              the window less the entry's maxTokens, at 4 characters a
#              token, which opens with a marker the reply has to repeat.
#
# Sources checked, so a pin in either is covered:
#   ~/.pi/agent/models.json   the mcloud provider's models, what the engine can select
#   alamode-seats list         every seat in the host's seats file whose
#                             provider is mcloud, its :level split off.
#                             Skipped on a host without alamode-seats.
#
# The live check is not a flake check: it needs the network and a
# credential, and `nix flake check` has neither (nix/checks/mcloud-pins.nix
# runs this against a stub endpoint). Not a models.json generator either.
# `GET /v1/models` returns only id/object/created/owned_by, so contextWindow,
# maxTokens, cost, thinkingLevelMap and the modality list, which is
# everything deciding how the engine drives a model, would have to be invented
# rather than fetched. The alamode module owns that file declaratively and
# overwrites it on every activation.

: "${GREEN_PNG:?path to the known image}"
readonly GREEN_PNG
readonly IMAGE_PROMPT="What color fills this image? Reply with one lowercase word."
readonly SUM_PROMPT="A shop sells pens at 3 dollars each and notebooks at 7 dollars each. Ana buys 4 pens and 3 notebooks and pays with a 50 dollar bill. How many dollars of change does she get? Reply with the number only."
readonly SUM=17
readonly TOOL_PROMPT="What is the weather in Paris? Use the tool."
readonly TOOLS='[{"type": "function", "function": {"name": "get_weather", "description": "Current weather for a city.",
  "parameters": {"type": "object", "properties": {"city": {"type": "string"}}, "required": ["city"]}}}]'
readonly MARKER="quartz-pelican-4417"
readonly BUDGET=4096

# pi 1.0.0's reasoning_effort for an openai-completions entry at a seat's
# level: getSupportedThinkingLevels, clampThinkingLevel and the default
# thinkingFormat branch of its request builder. A level mapped to null, and
# xhigh or max without a mapping, is unsupported and clamps to the nearest
# supported one, searching up first. effort($l) is "<level the engine runs><TAB><what
# goes in reasoning_effort, empty for nothing>".
# shellcheck disable=SC2016 # a jq program
readonly ALAMODE_EFFORT='
def all_levels: ["off", "minimal", "low", "medium", "high", "xhigh", "max"];
def supported:
  (.thinkingLevelMap // {}) as $m
  | if .reasoning != true then ["off"]
    else [all_levels[] | . as $l
      | select(($m | has($l)) and $m[$l] == null | not)
      | select(($l | IN("xhigh", "max") | not) or ($m | has($l)))]
    end;
def clamp($l):
  supported as $ok
  | if ($l | IN($ok[])) then $l
    else (all_levels | index($l)) as $i
      | ([all_levels[$i:][], (all_levels[:$i] | reverse[]) | select(IN($ok[]))] + [$ok[0] // "off"])[0]
    end;
def effort($l):
  clamp($l) as $e
  | (.thinkingLevelMap // {}) as $m
  | [$e, (if .reasoning != true or .compat.supportsReasoningEffort == false then ""
      elif $e == "off" then ($m.off | if type == "string" then . else "" end)
      else $m[$e] // $e end)]
  | @tsv;
'

DEPLOY=""
CONTEXT=""
case "$#:${1:-}" in
0:) ;;
1:--deploy) DEPLOY=1 ;;
1:--context) CONTEXT=1 ;;
*)
	echo "usage: mcloud-pins [--deploy | --context]" >&2
	exit 2
	;;
esac
readonly DEPLOY CONTEXT

SOPS_FILE="$(alamode-seats source 2>/dev/null || true)"
[ -n "$SOPS_FILE" ] || SOPS_FILE="this host's sops file"
readonly IN_SOPS="in $SOPS_FILE"

# die <what> <fix>: a failure before any model is checked.
die() {
	printf 'mcloud-pins: %s\n  fix: %s\n' "$1" "$2" >&2
	exit 2
}

# down <what> <if it keeps failing>: the endpoint as a whole is unreachable or
# failing. By hand that fails the run. --deploy runs after the switch has
# landed, and an outage says nothing about this host's config, so there it
# warns and exits 0.
down() {
	if [ -z "$DEPLOY" ]; then
		die "$1" "rerun mcloud-pins; if it fails the same way, $2"
	fi
	printf 'mcloud-pins: warning: %s, so no pin was checked\n  fix: rerun mcloud-pins once the endpoint answers; if it keeps failing, %s\n' "$1" "$2" >&2
	exit 0
}

plural() {
	if [ "$1" = 1 ]; then echo "1 $2"; else echo "$1 $2s"; fi
}

# The key goes to whatever baseUrl this file names, and every sandboxed alamode
# session can write ~/.pi, so the link must be home-manager's. Only the first
# hop is checked: that store link is an mkOutOfStoreSymlink on to
# /run/secrets/alamode_models_json, which sops-nix writes at activation.
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
		"set hmFoundry.dev.alamode.modelsJsonFile (or modelsJson) for this host and deploy, after moving aside anything else at that path"
	;;
esac

jq empty "$MODELS_JSON" 2>/dev/null ||
	die "$HOME/.pi/agent/models.json links to $MODELS_JSON, which is not readable JSON" \
		"add alamode_models_json, holding the catalog as JSON, $IN_SOPS and deploy, so sops-nix writes the file it points at"

# The endpoint belongs with the provider definition: this repo names no model
# ids and no base URLs, both arrive in models.json from the host's sops secret.
BASE_URL="$(jq -r '(.providers.mcloud.baseUrl)? // empty' "$MODELS_JSON")"
readonly BASE_URL
[ -n "$BASE_URL" ] ||
	die "alamode_models_json has no providers.mcloud.baseUrl, so there is no endpoint to check" \
		"set providers.mcloud.baseUrl in alamode_models_json $IN_SOPS"

if [ -z "${MCLOUD_API_KEY:-}" ]; then
	[ -n "${MCLOUD_API_KEY_COMMAND:-}" ] ||
		die "no mcloud key: MCLOUD_API_KEY and MCLOUD_API_KEY_COMMAND are unset, and this mcloud-pins was built without a keyCommand" \
			"set keyCommand where this host installs mcloud-pins (nix/hosts/<host>/configuration.nix) and deploy; MCLOUD_API_KEY or MCLOUD_API_KEY_COMMAND covers a single run"
	rc=0
	MCLOUD_API_KEY="$(sh -c "$MCLOUD_API_KEY_COMMAND")" || rc=$?
	[ -n "$MCLOUD_API_KEY" ] ||
		die "the key command printed no key (exit $rc): $MCLOUD_API_KEY_COMMAND" \
			"run that command by hand and fix what it reports, or point keyCommand, where this host installs mcloud-pins, at the key's real location"
fi

# api <seconds> <path> [-]: the response body, then the HTTP status on a line
# of its own, 000 when nothing answered. With `-` the request body is stdin.
# The key and the body reach curl through a file descriptor and stdin rather
# than its argv, which any user can read with ps.
api() {
	local args=(-s --max-time "$1" -w '\n%{http_code}')
	if [ $# -gt 2 ]; then
		args+=(-H "Content-Type: application/json" --data-binary @-)
	fi
	curl "${args[@]}" -H @<(printf 'Authorization: Bearer %s\n' "$MCLOUD_API_KEY") \
		"$BASE_URL/$2" || true
}

resp="$(api 30 models)"
code="${resp##*$'\n'}"
case "$code" in
200) ;;
000)
	down "GET /models at the mcloud baseUrl got no answer within 30s" \
		"check the network, then providers.mcloud.baseUrl in alamode_models_json $IN_SOPS"
	;;
429 | 5[0-9][0-9])
	down "GET /models answered HTTP $code" \
		"check the network, then providers.mcloud.baseUrl in alamode_models_json $IN_SOPS"
	;;
401 | 403)
	die "GET /models answered HTTP $code, so the endpoint refuses the key" \
		"check the key: MCLOUD_API_KEY when set, else what MCLOUD_API_KEY_COMMAND or this host's keyCommand for mcloud-pins prints"
	;;
404)
	die "GET /models answered HTTP 404, so the baseUrl is not an OpenAI-compatible API root" \
		"correct providers.mcloud.baseUrl in alamode_models_json $IN_SOPS"
	;;
*)
	die "GET /models answered HTTP $code" \
		"rerun mcloud-pins; if it fails the same way, check providers.mcloud.baseUrl in alamode_models_json $IN_SOPS"
	;;
esac
served="$(jq -r '.data[]?.id // empty' <<<"${resp%$'\n'*}" 2>/dev/null | sort -u || true)"
[ -n "$served" ] ||
	die "GET /models answered 200 with no model ids" \
		"check that providers.mcloud.baseUrl in alamode_models_json $IN_SOPS is the mcloud API root"

# Per id: the seat vars naming it, its catalog positions, whether its entry
# declares image input. seat_list holds "id<TAB>var<TAB>level" lines, the
# level empty when the seat names none.
declare -A seat_vars=() entries=() image=()
seat_list=""
while IFS=$'\t' read -r n id sees; do
	entries[$id]+="${entries[$id]:+, }alamode_models_json providers.mcloud.models[$n]"
	if [ "$sees" = true ]; then image[$id]=1; fi
done < <(jq -r '(.providers.mcloud.models)? // [] | to_entries[]
	| select(.value.id | type == "string" and . != "")
	| [.key, .value.id, ((.value.input // []) | any(. == "image"))] | @tsv' "$MODELS_JSON")
if command -v alamode-seats >/dev/null; then
	seats="$(alamode-seats list)" ||
		die "alamode-seats list failed, so no seat was checked" \
			"run alamode-seats check --deploy and fix what it reports"
	while IFS=$'\t' read -r var value; do
		[[ $value == mcloud/* ]] || continue
		id="${value#mcloud/}"
		level=""
		case "${id##*:}" in
		off | minimal | low | medium | high | xhigh | max)
			level="${id##*:}"
			id="${id%:*}"
			;;
		esac
		seat_vars[$id]+="${seat_vars[$id]:+, }$var"
		seat_list+="$id"$'\t'"$var"$'\t'"$level"$'\n'
	done <<<"$seats"
fi
[ ${#entries[@]} -gt 0 ] || [ ${#seat_vars[@]} -gt 0 ] ||
	die "nothing names an mcloud model: alamode_models_json has no providers.mcloud.models and no seat starts with mcloud/" \
		"list this host's models in alamode_models_json providers.mcloud.models and point ALAMODE_SESSION_MODEL at one of them, $IN_SOPS"
ids="$(printf '%s\n' "${!entries[@]}" "${!seat_vars[@]}" | sort -u)"

IMAGE_URL="data:image/png;base64,$(base64 -w0 "$GREEN_PNG")"
readonly IMAGE_URL

report=""
problems=0
warnings=0
# problem|warning <what> <fix>, about $subject.
problem() {
	report+="mcloud-pins: $subject: $1"$'\n'"  fix: $2"$'\n'
	problems=$((problems + 1))
}
warning() {
	report+="mcloud-pins: warning: $subject: $1"$'\n'"  fix: $2"$'\n'
	warnings=$((warnings + 1))
}
# unanswered <what> <fix>: a check that got no answer, a 429 or a 5xx, which
# says nothing about the pin. By hand that is a problem to rerun; under
# --deploy, as with down, it only warns.
unanswered() {
	if [ -n "$DEPLOY" ]; then
		warning "$1, so it was not checked" "rerun mcloud-pins once the endpoint answers"
	else
		problem "$1" "rerun mcloud-pins; if it fails the same way, $2"
	fi
}
# about <where>: the subject of what follows, the id itself left out of
# --deploy output.
about() {
	if [ -n "$DEPLOY" ]; then subject="$1"; else subject="$id ($1)"; fi
}
# verdict <problems> <warnings>, counted before a check: how it went.
verdict() {
	if [ "$problems" -gt "$1" ]; then
		echo FAIL
	elif [ "$warnings" -gt "$2" ]; then
		echo warn
	else
		echo ok
	fi
}

# chat <seconds>: POST stdin to chat/completions; sets code and body.
chat() {
	local resp
	resp="$(api "$1" chat/completions -)"
	code="${resp##*$'\n'}"
	body="${resp%$'\n'*}"
}
reply() {
	jq -r '.choices[0].message.content // empty' <<<"$body" 2>/dev/null || true
}
finish() {
	jq -r '.choices[0].finish_reason // empty' <<<"$body" 2>/dev/null || true
}
# said / it_said <reply>: the endpoint's error message or the model's reply,
# for plain output; --deploy prints neither, since either can echo an id.
said() {
	[ -z "$DEPLOY" ] || return 0
	local m
	m="$(jq -r '.error.message? // .message? // empty' <<<"$body" 2>/dev/null || true)"
	m="${m//[[:space:]]/ }"
	[ -z "$m" ] || printf ' (the endpoint said: %s)' "${m:0:200}"
}
it_said() {
	if [ -n "$DEPLOY" ] || [ -z "$1" ]; then return 0; fi
	local r="${1//[[:space:]]/ }"
	printf ' (it said: %s)' "${r:0:80}"
}
# load: $id's catalog entry into entry, empty when it has none, and the token
# field the engine sends for it into tf.
load() {
	# pi 1.0.0's modelFromJson: the provider's compat with the entry's over it.
	entry="$(jq -c --arg id "$id" '(.providers.mcloud.compat // {}) as $pc
		| [(.providers.mcloud.models)?[]? | select(.id? == $id)][0] // empty
		| .compat = $pc + (.compat // {})' "$MODELS_JSON")"
	tf="$(jq -r 'if .compat.maxTokensField == "max_tokens" then "max_tokens" else empty end' <<<"$entry")"
	tf="${tf:-max_completion_tokens}"
}

# Each check reads the id the loop is on: id, at, vars, entry, tf.
check_image() {
	local fix req r f
	about "$vars${vars:+, }$at"
	fix="remove \"image\" from input in $at${vars:+, or point $vars at a model that sees images}, $IN_SOPS"
	req="$(jq -nc --arg model "$id" --arg tf "$tf" --arg text "$IMAGE_PROMPT" --arg url "$IMAGE_URL" '{model: $model,
		($tf): 1024, messages: [{role: "user", content: [{type: "text", text: $text},
		{type: "image_url", image_url: {url: $url}}]}]}')"
	chat 120 <<<"$req"
	r="$(reply)"
	case "$code" in
	200) ;;
	000)
		unanswered "the image check got no answer within 120s" "$fix"
		return
		;;
	429 | 5??)
		unanswered "the image check answers HTTP $code$(said)" "$fix"
		return
		;;
	*)
		problem "the image check answers HTTP $code$(said), so the endpoint refuses the image or the request" "$fix"
		return
		;;
	esac
	if [ -z "$r" ]; then
		f="$(finish)"
		problem "the image check answered 200 with no text${f:+ (finish_reason $f)}, probably all 1024 tokens spent reasoning" \
			"a model that cannot name one color in 1024 tokens starves an image seat: $fix"
	elif ! grep -qiw green <<<"$r"; then
		problem "the image check's reply does not name green$(it_said "$r"), so the endpoint drops the image or the model cannot see it" "$fix"
	fi
}

# check_reason <level> <vars at that level>
check_reason() {
	local level=$1 who=$2 runs effort lv sent req tokens thought what r f fix
	about "$who, $at"
	if jq -e '.reasoning == true and .compat.thinkingFormat != null' <<<"$entry" >/dev/null; then
		warning "the reasoning check at level $level was skipped: compat.thinkingFormat is set, and the engine sends reasoning in that format's shape, which mcloud-pins does not mirror" \
			"confirm by hand that this model reasons at level $level, or drop compat.thinkingFormat from $at if the endpoint takes reasoning_effort, $IN_SOPS"
		return
	fi
	IFS=$'\t' read -r runs effort < <(jq -r --arg l "$level" "$ALAMODE_EFFORT effort(\$l)" <<<"$entry")
	lv="level $level"
	[ "$runs" = "$level" ] || lv+=" (the engine clamps it to $runs)"
	if [ -n "$effort" ]; then sent="reasoning_effort $effort"; else sent="no reasoning_effort"; fi
	req="$(jq -nc --arg model "$id" --arg tf "$tf" --argjson n "$BUDGET" --arg text "$SUM_PROMPT" --arg effort "$effort" \
		'{model: $model, ($tf): $n, messages: [{role: "user", content: $text}]}
		+ (if $effort == "" then {} else {reasoning_effort: $effort} end)')"
	chat 300 <<<"$req"
	fix="correct thinkingLevelMap, reasoning or compat.supportsReasoningEffort in $at so the engine sends what the endpoint takes, or pick another level for $who, $IN_SOPS"
	case "$code" in
	200) ;;
	000)
		unanswered "the reasoning check at $lv got no answer within 300s" "$fix"
		return
		;;
	429 | 5??)
		unanswered "the reasoning check at $lv answers HTTP $code$(said)" "$fix"
		return
		;;
	*)
		problem "the reasoning check at $lv answers HTTP $code$(said) to $sent" "$fix"
		return
		;;
	esac

	tokens="$(jq -r '.usage.completion_tokens_details.reasoning_tokens | numbers' <<<"$body" 2>/dev/null || true)"
	thought="$(jq -r '.choices[0].message | [.reasoning_content, .reasoning]
		| map(select(. != null and . != "")) | .[0] // "" | if type == "string" then . else tojson end' <<<"$body" 2>/dev/null || true)"
	if [ "${tokens:-0}" -gt 0 ]; then
		thought="${tokens} reasoning tokens"
	elif [ -n "$thought" ]; then
		thought="reasoning text"
	fi
	if [ "$runs" = off ]; then
		if [ -n "$thought" ]; then
			if [ "$level" = off ]; then
				what="reasons at off: a seat at :off still spends its budget thinking"
			else
				what="reasons at $lv: the seat still spends its budget thinking"
			fi
			problem "$what ($thought with $sent)" \
				"set \"reasoning\": true and a thinkingLevelMap.off that turns reasoning off in $at (the engine sends it at off), or point $who at a model that answers without reasoning, $IN_SOPS"
		fi
	elif [ -z "$thought" ] && [ -n "$tokens" ]; then
		problem "accepted $lv and did no reasoning, so the level is ignored (0 reasoning tokens with $sent)" \
			"correct thinkingLevelMap, reasoning or compat.supportsReasoningEffort in $at to what this model honours, or drop the level from $who, $IN_SOPS"
	elif [ -z "$thought" ]; then
		warning "cannot tell whether $lv reasons; the endpoint reports no reasoning tokens ($sent)" \
			"confirm by hand that this model reasons with $sent; if it does not, drop the level from $who, $IN_SOPS"
	fi

	r="$(reply)"
	f="$(finish)"
	fix="a three-step sum should not need $BUDGET tokens: lower the level in $who, or point it at another model, $IN_SOPS"
	if [ -z "$r" ]; then
		problem "the reasoning check at $lv answered with no text${f:+ (finish_reason $f)}" "$fix"
	elif [ "$f" = length ]; then
		problem "the reasoning check at $lv was cut off at the $BUDGET-token budget (finish_reason length)" "$fix"
	elif ! grep -qw "$SUM" <<<"$r"; then
		warning "the reasoning check at $lv answered, but not $SUM$(it_said "$r")" \
			"rerun mcloud-pins; a model that keeps missing a three-step sum is a poor fit for $who"
	fi
}

check_tools() {
	local fix req call name called
	about "$tvars, $at"
	fix="point $tvars at a model that calls tools, $IN_SOPS"
	req="$(jq -nc --arg model "$id" --arg tf "$tf" --argjson n "$BUDGET" --arg text "$TOOL_PROMPT" --argjson tools "$TOOLS" \
		'{model: $model, ($tf): $n, messages: [{role: "user", content: $text}], tools: $tools, tool_choice: "auto"}')"
	chat 300 <<<"$req"
	case "$code" in
	200) ;;
	000)
		unanswered "the tool check got no answer within 300s" "$fix"
		return
		;;
	429 | 5??)
		unanswered "the tool check answers HTTP $code$(said)" "$fix"
		return
		;;
	*)
		problem "the tool check answers HTTP $code$(said), so the endpoint refuses a request with tools" "$fix"
		return
		;;
	esac
	call="$(jq -c '.choices[0].message.tool_calls[0].function // empty' <<<"$body" 2>/dev/null || true)"
	name="$(jq -r '.name // empty' <<<"$call" 2>/dev/null || true)"
	if [ -z "$call" ]; then
		problem "the tool check got prose, not a tool call$(it_said "$(reply)"), so the model does not call tools here" "$fix"
	elif [ "$name" != get_weather ]; then
		called="${name:-a tool with no name}"
		[ -z "$DEPLOY" ] || called="another tool"
		problem "the tool check called $called, not get_weather" "$fix"
	elif ! jq -e '.arguments | if type == "string" then fromjson else . end | type == "object"' <<<"$call" >/dev/null 2>&1; then
		problem "the tool check called get_weather with arguments that are not a JSON object$(it_said "$(jq -r '.arguments | tostring' <<<"$call")")" "$fix"
	elif ! jq -e '.arguments | if type == "string" then fromjson else . end | .city | strings | test("paris"; "i")' <<<"$call" >/dev/null 2>&1; then
		problem "the tool check called get_weather without city Paris$(it_said "$(jq -r '.arguments | tostring' <<<"$call")")" "$fix"
	fi
}

check_context() {
	local window max n chars fix head tail
	about "$at"
	window="$(jq -r '.contextWindow | floor' <<<"$entry")"
	max="$(jq -r '.maxTokens // 0 | floor' <<<"$entry")"
	n=$((window * 9 / 10 - max))
	[ "$n" -gt 0 ] || n=$((window / 2))
	fix="lower contextWindow in $at to what the endpoint serves, $IN_SOPS"
	head="Remember this marker: $MARKER"$'\n\n'
	tail=$'\n\n'"What was the marker at the very start of this message? Reply with the marker only."
	chars=$((n * 4 - ${#head} - ${#tail}))
	[ "$chars" -gt 0 ] || chars=0
	echo "mcloud-pins (context): $id: about $n prompt tokens, contextWindow $window..." >&2
	chat 900 < <(
		{
			printf '%s' "$head"
			yes "The quick brown fox jumps over the lazy dog." | head -c "$chars" || true
			printf '%s' "$tail"
		} | jq -Rsc --arg model "$id" --arg tf "$tf" --argjson n "$BUDGET" \
			'{model: $model, ($tf): $n, messages: [{role: "user", content: .}]}'
	)
	case "$code" in
	200) ;;
	000)
		problem "the context check (about $n tokens) got no answer within 900s" "rerun mcloud-pins --context; if it fails the same way, $fix"
		return
		;;
	*)
		if [ "$code" = 400 ] || [ "$code" = 413 ] || said | grep -qiE 'context|too long|too many tokens|maximum.*length'; then
			problem "the endpoint rejects a prompt of about $n tokens, under the declared contextWindow $window: HTTP $code$(said)" "$fix"
		else
			problem "the context check (about $n tokens) answers HTTP $code$(said)" "rerun mcloud-pins --context; if it fails the same way, $fix"
		fi
		return
		;;
	esac
	if ! reply | grep -qF -- "$MARKER"; then
		problem "the context check (about $n tokens, contextWindow $window) answered without the marker from the prompt's start$(it_said "$(reply)"), so the endpoint truncates long prompts or the model loses the start" "$fix"
	fi
}

# row <model> <listed> <probe> <image> <reason> <tools> <context> <pinned in>
row() {
	[ -z "$DEPLOY" ] || return 0
	if [ -n "$CONTEXT" ]; then
		printf '%-30s %-8s %-6s %-6s %-6s %-6s %-8s %s\n' "$@"
	else
		printf '%-30s %-8s %-6s %-6s %-6s %-6s %s\n' "${@:1:6}" "$8"
	fi
}

# Every listed pin is probed before any is reported. When none answers, each
# getting no answer or a 5xx, the endpoint is failing completions rather than
# this host's pins, which is an outage the same as GET /models failing. One
# answer of any other kind, a 429 included, makes the rest per-pin problems.
declare -A probed=() heard=()
answered=""
while read -r id; do
	printf '%s\n' "$served" | grep -qxF -- "$id" || continue
	load
	req="$(jq -nc --arg model "$id" --arg tf "$tf" '{model: $model, ($tf): 1, messages: [{role: "user", content: "hi"}]}')"
	chat 60 <<<"$req"
	# One failed request says little about a pin: mcloud has refused a
	# sound id with a 401 after GET /models took the key, and let a probe
	# that usually takes under a second hang to the timeout. A dead pin
	# fails every time, so only a second failure counts. A 429 already
	# shows the id routes.
	case "$code" in
	000 | 401 | 403 | 5??)
		sleep 5
		chat 60 <<<"$req"
		;;
	esac
	probed[$id]=$code
	heard[$id]="$(said)"
	case "$code" in
	000 | 5??) ;;
	*) answered=1 ;;
	esac
done <<<"$ids"
if [ ${#probed[@]} -gt 0 ] && [ -z "$answered" ]; then
	got="$(printf '%s\n' "${probed[@]}" | grep -vx 000 | sort -u | paste -sd/ - || true)"
	got="${got:+HTTP $got}"
	if printf '%s\n' "${probed[@]}" | grep -qx 000; then got+="${got:+ or }no answer within 60s"; fi
	down "GET /models answers, but a one-token completion to every listed pin got $got" \
		"the endpoint is failing completions while GET /models accepts the key at this baseUrl, so wait it out rather than change this host's config"
fi

npins=0
ok_image=0
ok_reason=0
ok_tools=0
ok_context=0
row MODEL LISTED PROBE IMAGE REASON TOOLS CONTEXT 'PINNED IN'
while read -r id; do
	npins=$((npins + 1))
	vars="${seat_vars[$id]:-}"
	at="${entries[$id]:-}"
	where="$vars${vars:+${at:+, }}$at"
	about "$where"
	load

	# Seats: the vars per level, and the vars whose consumer hands out tools.
	declare -A lvars=()
	tvars=""
	while IFS=$'\t' read -r sid var level; do
		[ "$sid" = "$id" ] || continue
		if [ -n "$level" ]; then lvars[$level]+="${lvars[$level]:+, }$var"; fi
		case "$var" in
		ALAMODE_SESSION_MODEL | ALAMODE_SPAWN_MODEL | ALAMODE_DELEGATE_MODEL | ALAMODE_AGENT_MODEL_*) tvars+="${tvars:+, }$var" ;;
		esac
	done <<<"$seat_list"

	listed=NO
	probe=skip
	sight=-
	reason=-
	tools=-
	ctx=-
	[ -z "${image[$id]:-}" ] || sight=skip
	[ ${#lvars[@]} -eq 0 ] || reason=skip
	[ -z "$tvars" ] || tools=skip
	if [ -n "$CONTEXT" ] && jq -e '.contextWindow | numbers' <<<"$entry" >/dev/null 2>&1; then ctx=skip; fi

	if [ -z "$at" ]; then
		problem "a seat names this mcloud model, but alamode_models_json has no entry for it, so the engine cannot select it" \
			"add an entry for it to alamode_models_json providers.mcloud.models, or point $vars at a catalogued model, $IN_SOPS"
	fi

	if printf '%s\n' "$served" | grep -qxF -- "$id"; then
		listed=yes
		probe="${probed[$id]}"
		# 429 came from the model's own endpoint, so the id routes and the
		# pin is sound; the throttle is this script's own fault for asking.
		case "$probe" in
		200 | 429) ;;
		000)
			problem "a one-token completion got no answer within 60s" \
				"rerun mcloud-pins; if it fails the same way, replace the model in $where, $IN_SOPS"
			;;
		400)
			problem "listed, but a one-token completion answers HTTP 400${heard[$id]} to $tf, the token field the engine sends" \
				"${at:+if the endpoint takes another token field, set compat.maxTokensField in $at to it; otherwise }replace the model in $where, $IN_SOPS"
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

	if [ -n "$entry" ] && { [ "$probe" = 200 ] || [ "$probe" = 429 ]; }; then
		if [ "$sight" = skip ]; then
			p=$problems w=$warnings
			check_image
			sight="$(verdict "$p" "$w")"
			[ "$sight" != ok ] || ok_image=$((ok_image + 1))
		fi
		if [ "$reason" = skip ]; then
			p0=$problems w0=$warnings
			for level in off minimal low medium high xhigh max; do
				[ -n "${lvars[$level]:-}" ] || continue
				p=$problems w=$warnings
				check_reason "$level" "${lvars[$level]}"
				[ "$(verdict "$p" "$w")" != ok ] || ok_reason=$((ok_reason + 1))
			done
			reason="$(verdict "$p0" "$w0")"
		fi
		if [ "$tools" = skip ]; then
			p=$problems w=$warnings
			check_tools
			tools="$(verdict "$p" "$w")"
			[ "$tools" != ok ] || ok_tools=$((ok_tools + 1))
		fi
		if [ "$ctx" = skip ]; then
			p=$problems w=$warnings start=$SECONDS
			check_context
			ctx="$(verdict "$p" "$w")"
			[ "$ctx" != ok ] || ok_context=$((ok_context + 1))
			tokens="$(jq -r '.usage.prompt_tokens | numbers' <<<"$body" 2>/dev/null || true)"
			echo "mcloud-pins (context): $id: $ctx in $((SECONDS - start))s${tokens:+, $tokens prompt tokens}" >&2
		fi
	fi
	unset lvars

	row "$id" "$listed" "$probe" "$sight" "$reason" "$tools" "$ctx" "$where"
done <<<"$ids"

# Served but nothing points at it. Not a failure, just the other half of the
# picture when picking a model.
if [ -z "$DEPLOY" ]; then
	unpinned="$(comm -23 <(printf '%s\n' "$served") <(printf '%s\n' "$ids") | paste -sd' ' -)"
	if [ -n "$unpinned" ]; then printf '\nserved, unpinned: %s\n' "$unpinned"; fi
fi

[ -n "$DEPLOY" ] || [ "$problems$warnings" = 00 ] || echo
printf '%s' "$report" >&2
if [ "$problems" -ne 0 ]; then
	summary="$(plural "$problems" problem)"
	[ "$warnings" = 0 ] || summary+=" and $(plural "$warnings" warning)"
	echo "mcloud-pins: $summary across $(plural "$npins" pin), each with its fix above" >&2
	exit 1
fi
passed=("$(plural "$ok_image" "image check")" "$(plural "$ok_reason" "reasoning check")" "$(plural "$ok_tools" "tool check")")
[ -z "$CONTEXT" ] || passed+=("$(plural "$ok_context" "context check")")
printf -v list '%s, ' "${passed[@]:0:${#passed[@]}-1}"
list="${list%, } and ${passed[-1]}"
[ -n "$DEPLOY" ] || echo
echo "mcloud-pins: $(plural "$npins" pin) served and answering, $list passed$([ "$warnings" = 0 ] || echo ", $(plural "$warnings" warning) above")"
