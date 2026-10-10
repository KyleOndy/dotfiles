# shellcheck shell=bash
# writeShellApplication provides the shebang and `set -euo pipefail`; this
# file is only the body (nix/pkgs/mcloud-rank/default.nix).
#
# Ranks the models mcloud serves by the Artificial Analysis
# Intelligence Index, one score per reasoning effort, and asks each model
# whether it thinks.
#
#   mcloud-rank
#
# Each key is its variable, MCLOUD_API_KEY or AA_API_KEY, or else whatever
# the matching _COMMAND variable prints, which each host sets to its own
# secret store.
#
# The AA free API allows 1,000 requests a day, and a run makes one:
# https://artificialanalysis.ai/documentation
#
# Never name a served model in this file, not even as an example: the
# endpoint can serve models before their public release, and this repo is
# public.

readonly AA_URL="https://artificialanalysis.ai/api/v2/data/llms/models"

[ -n "${MCLOUD_API_KEY:-}" ] || MCLOUD_API_KEY="$(sh -c "${MCLOUD_API_KEY_COMMAND:-true}")"
[ -n "${AA_API_KEY:-}" ] || AA_API_KEY="$(sh -c "${AA_API_KEY_COMMAND:-true}")"
if [ -z "$MCLOUD_API_KEY" ] || [ -z "$AA_API_KEY" ]; then
	echo "mcloud-rank: set MCLOUD_API_KEY and AA_API_KEY, or MCLOUD_API_KEY_COMMAND and AA_API_KEY_COMMAND to commands that print them" >&2
	exit 2
fi

# The key goes to whatever baseUrl the catalog names, and every sandboxed pi
# session can write ~/.pi, so the link must be home-manager's. This repo names
# no base URL; it arrives in models.json from the host's sops secret.
MODELS_JSON="$(readlink "$HOME/.pi/agent/models.json" 2>/dev/null || true)"
readonly MODELS_JSON
if [[ $MODELS_JSON != /nix/store/* ]]; then
	echo "mcloud-rank: ~/.pi/agent/models.json is not a link into /nix/store (${MODELS_JSON:-missing}), so home-manager did not write it and its baseUrl is not trusted with the key" >&2
	exit 2
fi
API_URL="$(jq -r '(.providers.mcloud.baseUrl)? // empty' "$MODELS_JSON")"
readonly API_URL
if [ -z "$API_URL" ]; then
	echo "mcloud-rank: models.json has no providers.mcloud.baseUrl" >&2
	exit 2
fi

live=$(curl -fsS --max-time 30 "$API_URL/models" -H "Authorization: Bearer $MCLOUD_API_KEY")
aa=$(curl -fsS --max-time 30 "$AA_URL" -H "x-api-key: $AA_API_KEY")

# Served ids and AA slugs spell one model differently. A served id can carry
# an org prefix and a quantization suffix (Org/Name-1.5-FP8); the AA slug
# drops both, spells the version with dashes (name-1-5) and drops an
# instruct suffix.
#
# So a score is AA's for the model, not for this endpoint's deployment of it.
# AA publishes no precision for its runs, and neither GET /v1/models nor an
# id without a suffix says what this endpoint serves. The loss depends on the
# format: FP8 is effectively lossless, tuned INT8 costs 1-3% and INT4
# weight-only is close to 8-bit (https://arxiv.org/abs/2411.02355).
#
# AA publishes one row per reasoning effort it measured, with the effort in
# the name, "Name (High)", and as a slug suffix, name-high. The bare slug is
# the model's default effort, also labeled: (Max) on newer models,
# (Non-reasoning) on older hybrids, whose thinking row is then
# name-reasoning. A name without a parenthetical is a model of its own, so
# its slug keeps any suffix: name-max can be a whole model rather than an
# effort. DEF collects the rows that name no effort, (Reasoning) included.
# TOP compares a model's best row with AA's best row overall.
# shellcheck disable=SC2016
rows=$(jq -rn --argjson live "$live" --slurpfile aa <(printf '%s' "$aa") '
	def norm:
		ascii_downcase | split("/")[-1]
		| sub("-(mxfp8|fp8|fp4|nvfp4|awq|gptq|int8|bf16)$"; "")
		| sub("-(it|instruct)$"; "")
		| gsub("\\."; "-");
	def score: .evaluations.artificial_analysis_intelligence_index;
	def base:
		if .name | test("\\(") then
			.slug | sub("-(max|xhigh|high|medium|low|minimal|non-reasoning|reasoning|thinking|adaptive)$"; "")
		else .slug end;
	def level:
		{"non-reasoning": "off", minimal: "min", low: "low", medium: "med", high: "high", xhigh: "xhigh", max: "max"}[
			.name | capture("\\((?<l>[^,)]+)").l | ascii_downcase] // "def";
	["off", "min", "low", "med", "high", "xhigh", "max", "def"] as $cols
	| ($aa[0].data | map(select(score != null))) as $scored
	| ($scored | max_by(score)) as $top
	| (reduce $scored[] as $r ({}; .[$r | base][$r | level] = ([.[$r | base][$r | level], ($r | score)] | max))) as $by_base
	| [$live.data[].id | {id: ., cells: $by_base[norm]}] as $models
	| "header\t\($top.name)\t\($top | score)",
	  ($models | map(select(.cells) | .best = ([.cells[]] | max)) | sort_by(-.best)[]
		| . as $m
		| ["ranked", .id, (.best / ($top | score) * 100), ($cols[] | $m.cells[.] // "-")] | map(tostring) | join("\t")),
	  ($models | map(select(.cells == null))[] | "unscored\t\(.id)")
')

# GET /v1/models carries no capability metadata, and the chat endpoint
# accepts every reasoning_effort value for every model, so whether a model
# thinks is only visible in its replies. Some models think by default, others
# only once an effort is sent, and "none" does not stop every model every
# time; a chat_template_kwargs switch is honored by fewer still. An adaptive
# model can skip thinking on a prompt that needs none, even at high, so the
# probe asks for a product. "?" is a request that failed.
reasoned() {
	local body
	body=$(jq -n --arg m "$1" --arg e "$2" '{model: $m, max_tokens: 64, messages: [{role: "user", content: "What is 17 * 23? Answer with the number only."}]}
		+ (if $e == "" then {} else {reasoning_effort: $e} end)' |
		curl -fsS --max-time 30 "$API_URL/chat/completions" \
			-H "Authorization: Bearer $MCLOUD_API_KEY" -H "Content-Type: application/json" -d @- 2>/dev/null) || {
		echo "?"
		return
	}
	jq -r '.usage.completion_tokens_details.reasoning_tokens // 0 as $t
		| (.choices[0].message | .reasoning_content // .reasoning // "") as $r
		| if $t > 0 or $r != "" then "yes" else "no" end' <<<"$body"
}

# Replies are sampled, so one says little: n/3 is how many of three
# concurrent replies reasoned.
thinks() {
	local replies n
	replies=$(
		for _ in 1 2 3; do reasoned "$1" "$2" & done
		wait
	)
	if [[ $replies == *'?'* ]]; then
		echo "?"
	else
		n=$(grep -c yes <<<"$replies" || true)
		echo "$n/3"
	fi
}

while IFS=$'\t' read -r kind id rest; do
	if [[ $kind == ranked ]]; then
		printf '%s\t%s\t%s\t%s %s %s\n' "$kind" "$id" "$rest" "$(thinks "$id" "")" "$(thinks "$id" high)" "$(thinks "$id" none)"
	else
		printf '%s\t%s\t%s\n' "$kind" "$id" "$rest"
	fi
done <<<"$rows" | awk -F'\t' '
	$1 == "header" {
		printf "Live on mcloud, AA Intelligence Index per reasoning effort.\n"
		printf "TOP: best score as a share of %s (%s). DEF: AA named no effort.\n", $2, $3
		printf "THINKS: replies that reasoned with no effort sent, high, none.\n\n"
		printf "  %-30s %5s %5s %5s %5s %5s %5s %5s %5s %5s  %s\n", "MODEL", "TOP", "OFF", "MIN", "LOW", "MED", "HIGH", "XHIGH", "MAX", "DEF", "THINKS"
	}
	$1 == "ranked" { printf "  %-30s %4.0f%% %5s %5s %5s %5s %5s %5s %5s %5s  %s\n", $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12 }
	$1 == "unscored" && !seen++ { print "\nNot on the AA Intelligence Index:" }
	$1 == "unscored" { print "  " $2 }
'
