# shellcheck shell=bash
# writeShellApplication provides the shebang and `set -euo pipefail`; this
# file is only the body (nix/pkgs/advisor-eval/default.nix), which also sets
# ADVISOR_TS and CASES to their store paths unless the caller already has.
#
# Grades candidate reviewer models for extensions/advisor.ts against labeled
# turns, so picking PI_ADVISOR_MODEL is a measurement rather than a guess.
#
#   MCLOUD_API_KEY=$(security find-generic-password -s work-secrets -a mcloud-inference -w) \
#     advisor-eval minimax/minimax-m3 qwen/qwen3.8-27b
#
# The system prompt, token budget and timeout are read out of advisor.ts
# itself, so a model is graded on exactly the request the advisor sends.
# cases.json holds each turn as summarizeTurn renders it.
#
# A leaderboard score does not predict this job. qwen3.8-27b outscores
# minimax-m3 on the AA Intelligence Index, yet at the advisor's budget it spent
# every token reasoning and returned nothing on a turn that deserved a steer.
#
# Verdicts: OK and STEER are what the prompt asks for. FORMAT is any other
# reply, which the advisor drops, so it counts as silence. EMPTY is no content,
# usually the budget spent on reasoning. ERROR is a non-200 or a timeout.
#
#   RUNS=3      requests per case per model; replies are sampled, so one run
#               says little about a model's error rate
#   PARALLEL=6  requests in flight at once

: "${ADVISOR_TS:?path to advisor.ts}"
: "${CASES:?path to cases.json}"
readonly RUNS="${RUNS:-3}"
readonly PARALLEL="${PARALLEL:-6}"

if [ "$#" -eq 0 ]; then
	echo "usage: advisor-eval MODEL..." >&2
	exit 2
fi

if [ -z "${MCLOUD_API_KEY:-}" ]; then
	cat >&2 <<-EOF
		advisor-eval: MCLOUD_API_KEY is unset.

		  work-mac: MCLOUD_API_KEY=\$(security find-generic-password -s work-secrets -a mcloud-inference -w) advisor-eval MODEL...
	EOF
	exit 2
fi

# The key goes to whatever baseUrl this file names, and every sandboxed pi
# session can write ~/.pi, so the link must be home-manager's. Only the first
# hop is checked: on work-mac that store link points on to a file in the work
# repo through mkOutOfStoreSymlink, which is home-manager's doing too.
MODELS_JSON="$(readlink "$HOME/.pi/agent/models.json" 2>/dev/null || true)"
readonly MODELS_JSON
case "$MODELS_JSON" in
/nix/store/*) ;;
*)
	echo "advisor-eval: ~/.pi/agent/models.json is not a link into /nix/store (${MODELS_JSON:-missing}), so it was not written by home-manager" >&2
	exit 2
	;;
esac
BASE_URL="$(jq -r '.providers.mcloud.baseUrl // empty' "$MODELS_JSON")"
readonly BASE_URL
if [ -z "$BASE_URL" ]; then
	echo "advisor-eval: no mcloud baseUrl in $MODELS_JSON" >&2
	exit 2
fi

SYSTEM_PROMPT="$(awk '
	/^const REVIEWER_SYSTEM_PROMPT = `/ { f = 1; sub(/^const REVIEWER_SYSTEM_PROMPT = `/, "") }
	f && /`;$/ { sub(/`;$/, ""); print; exit }
	f { print }
' "$ADVISOR_TS")"
readonly SYSTEM_PROMPT
ts_const() {
	grep -oE "^const $1 = [0-9_]+" "$ADVISOR_TS" | awk '{ gsub(/_/, "", $NF); print $NF }'
}
MAX_TOKENS="$(ts_const MAX_VERDICT_TOKENS)"
readonly MAX_TOKENS
TIMEOUT_MS="$(ts_const REQUEST_TIMEOUT_MS)"
readonly TIMEOUT_MS
if [ -z "$SYSTEM_PROMPT" ] || [ -z "$MAX_TOKENS" ] || [ -z "$TIMEOUT_MS" ]; then
	echo "advisor-eval: could not read REVIEWER_SYSTEM_PROMPT, MAX_VERDICT_TOKENS and REQUEST_TIMEOUT_MS out of $ADVISOR_TS" >&2
	exit 2
fi

results="$(mktemp -d "${TMPDIR:-/tmp}/advisor-eval.XXXXXX")"
readonly results

# Never fails: a refused or timed-out request is a result to grade, and under
# `set -e` a failing background job would end the whole run at `wait -n`.
ask() {
	local model=$1 case_index=$2 run=$3
	local out="$results/${model//\//_}.$case_index.$run"
	local case_json meta
	case_json="$(jq -c ".[$case_index]" "$CASES")"
	meta="$(jq -n \
		--arg model "$model" \
		--arg system "$SYSTEM_PROMPT" \
		--argjson max_tokens "$MAX_TOKENS" \
		--argjson case "$case_json" \
		'{model: $model, max_tokens: $max_tokens,
		  messages: [{role: "system", content: $system}, {role: "user", content: $case.turn}]}' |
		curl -sS -o "$out.body" -w '%{http_code} %{time_total}' \
			--max-time "$((TIMEOUT_MS / 1000))" \
			-H "Content-Type: application/json" \
			-H "Authorization: Bearer $MCLOUD_API_KEY" \
			-d @- "$BASE_URL/chat/completions" 2>/dev/null)" || true
	touch "$out.body"
	jq -n \
		--arg model "$model" \
		--argjson case "$case_json" \
		--arg meta "${meta:-000 0}" \
		--rawfile body "$out.body" \
		'($body | fromjson? // {}) as $r
		| ($meta | split(" ")) as [$code, $time]
		| ($r.choices[0].message.content // "" | trim) as $content
		| {model: $model, id: $case.id, expect: $case.expect, content: $content,
		   finish: $r.choices[0].finish_reason, tokens: $r.usage.completion_tokens,
		   seconds: ($time | tonumber),
		   verdict: (if $code != "200" then "ERROR"
		     elif $content == "" then "EMPTY"
		     elif ($content | test("^STEER:"; "i")) then "STEER"
		     elif ($content | test("^OK\\.?$"; "i")) then "OK"
		     else "FORMAT" end)}' >"$out.json"
}

cases="$(jq length "$CASES")"
total=$(($# * cases * RUNS))
echo "advisor-eval: $total requests ($# models x $cases cases x $RUNS runs), max_tokens $MAX_TOKENS, timeout ${TIMEOUT_MS}ms" >&2
for model in "$@"; do
	for ((c = 0; c < cases; c++)); do
		for ((r = 0; r < RUNS; r++)); do
			ask "$model" "$c" "$r" &
			if [ "$(jobs -rp | wc -l)" -ge "$PARALLEL" ]; then
				wait -n
			fi
		done
	done
done
wait

# missed: a STEER case that got anything else, the failure that matters most,
# since a silent advisor is no advisor. false: an OK case that got a STEER.
jq -rs '
	group_by(.model)
	| map({model: .[0].model, n: length,
	       correct: map(select(.verdict == .expect)) | length,
	       missed: map(select(.expect == "STEER" and .verdict != "STEER")) | length,
	       false: map(select(.expect == "OK" and .verdict == "STEER")) | length,
	       format: map(select(.verdict == "FORMAT")) | length,
	       empty: map(select(.verdict == "EMPTY")) | length,
	       error: map(select(.verdict == "ERROR")) | length,
	       tokens: (map(.tokens // empty) | if length > 0 then add / length | round else 0 end),
	       mean: (map(.seconds) | add / length * 10 | round / 10),
	       max: (map(.seconds) | max * 10 | round / 10)})
	| sort_by(-.correct, .mean)
	| (["MODEL", "CORRECT", "MISSED", "FALSE", "FORMAT", "EMPTY", "ERROR", "TOKENS", "MEAN_S", "MAX_S"],
	   (.[] | [.model, "\(.correct)/\(.n)", .missed, .false, .format, .empty, .error, .tokens, .mean, .max]))
	| @tsv
' "$results"/*.json | awk -F'\t' '{ printf "%-30s %-8s %-7s %-6s %-7s %-6s %-6s %-7s %-7s %s\n", $1, $2, $3, $4, $5, $6, $7, $8, $9, $10 }'

echo
echo "Wrong verdicts:"
jq -rs '
	map(select(.verdict != .expect))
	| sort_by(.model, .id)[]
	| "  \(.model)  \(.id)  want \(.expect), got \(.verdict): \(.content | gsub("\\s+"; " ") | .[0:100])"
' "$results"/*.json

echo
echo "Raw replies: $results"
