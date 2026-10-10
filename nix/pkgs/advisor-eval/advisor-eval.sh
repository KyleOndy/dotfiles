# shellcheck shell=bash
# writeShellApplication provides the shebang and `set -euo pipefail`; this
# file is only the body (nix/pkgs/advisor-eval/default.nix), which also puts
# pi's real binary first on PATH and sets CASES and ADVISOR_TS to their store
# paths unless the caller already has.
#
# Grades candidate reviewer models for extensions/advisor.ts against labeled
# turns, so picking PI_ADVISOR_MODEL is a measurement rather than a guess.
#
#   advisor-eval MODEL...
#
# MODEL is a seat value, provider/id[:level], for any model pi can reach,
# trusted or not: the cases are public and no session content goes out. Each
# run is a headless, unsandboxed pi that loads advisor.ts and runs its
# `/advisor ask`, which sends every case through the advisor's own request:
# its system prompt, token budget, timeout and the seat's reasoning level.
# cases.json holds each turn as summarizeTurn renders it.
#
# pi runs unsandboxed here, so it reads nothing a sandboxed session can write:
# its agent dir is a fresh one holding a copy of models.json and nothing
# else (no settings.json, no auth.json), and advisor.ts is the deployed copy
# in the store rather than the worktree file sessions load. The mcloud key is
# MCLOUD_API_KEY, or else whatever MCLOUD_API_KEY_COMMAND prints, which each
# host sets to its own secret store; models.json reads it as $MCLOUD_API_KEY.
# Other providers take their keys from this env only.
#
# The 2000-token budget in advisor.ts was measured with `max_tokens`. pi sends
# `max_completion_tokens` unless the model's compat sets maxTokensField, so
# that budget needs re-measuring with this tool: watch EMPTY and TOKENS.
#
# A leaderboard score does not predict this job. A model that outscores
# another on the AA Intelligence Index can still spend every token of the
# advisor's budget reasoning and return nothing on a turn that deserved a
# steer.
#
# Verdicts: OK and STEER are what the prompt asks for. FORMAT is any other
# reply, which the advisor drops, so it counts as silence. EMPTY is no text,
# usually the budget spent on reasoning. ERROR is a request pi reports as
# failed or aborted, a timeout included, or a case pi left no result for.
#
#   RUNS=3      runs per model; replies are sampled, so one run says little
#               about a model's error rate
#   PARALLEL=6  pi processes at once, each sending its cases one at a time
#   ADVISOR_TS  the advisor.ts to load; the default is the deployed one, so
#               grading an edit means pointing this at the worktree file

: "${CASES:?path to cases.json}"
: "${ADVISOR_TS:?path to advisor.ts}"
readonly ADVISOR_TS
readonly RUNS="${RUNS:-3}"
readonly PARALLEL="${PARALLEL:-6}"

if [ "$#" -eq 0 ]; then
	echo "usage: advisor-eval MODEL..." >&2
	exit 2
fi
if [ ! -r "$ADVISOR_TS" ]; then
	echo "advisor-eval: cannot read $ADVISOR_TS" >&2
	exit 2
fi

[ -n "${MCLOUD_API_KEY:-}" ] || MCLOUD_API_KEY="$(sh -c "${MCLOUD_API_KEY_COMMAND:-true}")"
[ -z "$MCLOUD_API_KEY" ] || export MCLOUD_API_KEY

# The key goes to whatever baseUrl this file names, an apiKey there can be a
# `!command`, and pi runs here unsandboxed while every sandboxed pi session
# can write ~/.pi, so the link must be home-manager's. Only the first hop is
# checked: a catalog kept outside the store is a store link that points on
# through mkOutOfStoreSymlink, which is home-manager's doing too.
MODELS_JSON="$(readlink "$HOME/.pi/agent/models.json" 2>/dev/null || true)"
readonly MODELS_JSON
case "$MODELS_JSON" in
/nix/store/*) ;;
*)
	echo "advisor-eval: ~/.pi/agent/models.json is not a link into /nix/store (${MODELS_JSON:-missing}), so it was not written by home-manager" >&2
	exit 2
	;;
esac

ts_const() {
	sed -nE "s/^const $1 = ([0-9_]+);.*/\1/p" "$ADVISOR_TS" | tr -d _
}
MAX_TOKENS="$(ts_const MAX_VERDICT_TOKENS)"
readonly MAX_TOKENS
TIMEOUT_MS="$(ts_const REQUEST_TIMEOUT_MS)"
readonly TIMEOUT_MS

results="$(mktemp -d "${TMPDIR:-/tmp}/advisor-eval.XXXXXX")"
readonly results
mkdir "$results/agent"
cp "$HOME/.pi/agent/models.json" "$results/agent/models.json"
export PI_CODING_AGENT_DIR="$results/agent"

# Never fails: pi exits non-zero when any request fails, which is a result to
# grade, and under `set -e` a failing background job would end the whole run
# at `wait -n`. A case pi wrote no line for grades as ERROR.
ask() {
	local model=$1 run=$2
	local out="$results/${model//\//_}.$run"
	pi -p --no-session --offline -ne -e "$ADVISOR_TS" --model "$model" \
		"/advisor ask $model $CASES $out.jsonl" </dev/null 2>"$out.log" || true
	touch "$out.jsonl"
	if [ ! -s "$out.jsonl" ]; then
		echo "advisor-eval: pi wrote no results for $model, run $run: $(tail -n1 "$out.log")" >&2
	fi
	jq -cn \
		--arg model "$model" \
		--slurpfile cases "$CASES" \
		--slurpfile got "$out.jsonl" \
		'$cases[0][] as $case
		| (first($got[] | select(.id == $case.id))
		   // {stopReason: "error", errorMessage: "no result from pi"}) as $r
		| ($r.stopReason == "error" or $r.stopReason == "aborted") as $failed
		| ($r.text // "") as $text
		| {model: $model, id: $case.id, expect: $case.expect,
		   content: (if $failed then $r.errorMessage // $r.stopReason else $text end),
		   finish: $r.stopReason, tokens: (if $failed then null else $r.usage.output end),
		   seconds: ($r.seconds // 0),
		   verdict: (if $failed then "ERROR"
		     elif $text == "" then "EMPTY"
		     elif ($text | test("^STEER:"; "i")) then "STEER"
		     elif ($text | test("^OK\\.?$"; "i")) then "OK"
		     else "FORMAT" end)}' >"$out.json"
}

cases="$(jq length "$CASES")"
total=$(($# * cases * RUNS))
echo "advisor-eval: $total requests ($# models x $cases cases x $RUNS runs), token budget $MAX_TOKENS, timeout ${TIMEOUT_MS}ms" >&2
for model in "$@"; do
	for ((r = 0; r < RUNS; r++)); do
		ask "$model" "$r" &
		if [ "$(jobs -rp | wc -l)" -ge "$PARALLEL" ]; then
			wait -n
		fi
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
echo "Raw replies and pi's logs: $results"
