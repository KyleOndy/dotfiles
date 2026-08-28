# shellcheck shell=bash
# writeShellApplication provides the shebang and `set -euo pipefail`; this
# file is only the body (nix/pkgs/mcloud-pins/default.nix).
#
# Checks that every mcloud model this machine registers or this repo names is
# actually served, and answers.
#
#   MCLOUD_API_KEY=$(security find-generic-password -s work-secrets -a mcloud-inference -w) mcloud-pins
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
# Sources checked, so a pin in any of them is covered:
#   ~/.pi/agent/models.json   what pi can actually select, including a private
#                             work-config file this repo cannot see
#   mcloud/<vendor>/<id>      every reference in the tree: sandbox.defaultArgs,
#                             agent frontmatter, domestique's classifyModel
#   advisor.ts                its own constant, unprefixed because it calls the
#                             endpoint directly rather than through pi
#
# Not a flake check: this needs the network and a credential, and `nix flake
# check` has neither. Not a models.json generator either. `GET /v1/models`
# returns only id/object/created/owned_by, so contextWindow, maxTokens, cost,
# thinkingLevelMap and the modality list, which is everything deciding how pi
# drives a model, would have to be invented rather than fetched. The pi module
# owns that file declaratively and overwrites it on every activation.

readonly MODELS_JSON="$HOME/.pi/agent/models.json"

# The endpoint belongs with the provider definition: this repo names no model
# ids and no base URLs, both arrive in models.json from the private work-config
# input (CLAUDE.md, "Pi coding agent").
BASE_URL="$(jq -r '.providers.mcloud.baseUrl // empty' "$MODELS_JSON" 2>/dev/null || true)"
readonly BASE_URL
if [ -z "$BASE_URL" ]; then
	echo "mcloud-pins: no mcloud baseUrl in $MODELS_JSON, so there is no endpoint to check" >&2
	exit 2
fi

if [ -z "${MCLOUD_API_KEY:-}" ]; then
	cat >&2 <<-EOF
		mcloud-pins: MCLOUD_API_KEY is unset.

		  work-mac: MCLOUD_API_KEY=\$(security find-generic-password -s work-secrets -a mcloud-inference -w) mcloud-pins
		  trex:     MCLOUD_API_KEY=\$(cat /run/secrets/trex_mcloud_api_key) mcloud-pins
	EOF
	exit 2
fi

root="$(git rev-parse --show-toplevel 2>/dev/null || true)"

# Every id the endpoint lists, one per line.
served="$(curl -fsS --max-time 30 -H "Authorization: Bearer $MCLOUD_API_KEY" \
	"$BASE_URL/models" | jq -r '.data[].id' | sort)"
if [ -z "$served" ]; then
	echo "mcloud-pins: $BASE_URL/models returned no models" >&2
	exit 1
fi

# Collect pins as "id<TAB>where", then fold to one line per id.
pins=""
while read -r id; do
	[ -n "$id" ] && pins+="$id	models.json"$'\n'
done < <(jq -r '.providers.mcloud.models[]?.id // empty' "$MODELS_JSON")
if [ -n "$root" ]; then
	while IFS=: read -r file _line match; do
		pins+="${match#mcloud/}	${file#"$root"/}"$'\n'
	done < <(grep -rnoE 'mcloud/[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+' \
		--include='*.nix' --include='*.ts' --include='*.md' --include='*.sh' \
		"$root" 2>/dev/null || true)
	while IFS=: read -r file _line match; do
		id="${match#*\"}"
		pins+="${id%\"}	${file#"$root"/}"$'\n'
	done < <(grep -rnoE 'ADVISOR_MODEL = "[^"]+"' --include='*.ts' "$root" 2>/dev/null || true)
fi

ids="$(printf '%s' "$pins" | cut -f1 | grep -v '^$' | sort -u)"
if [ -z "$ids" ]; then
	echo "mcloud-pins: found nothing pinned, which is itself suspicious" >&2
	exit 1
fi

# One-token completion. A listed model can still refuse every request.
probe() {
	curl -s -o /dev/null -w '%{http_code}' --max-time 60 \
		-H "Content-Type: application/json" \
		-H "Authorization: Bearer $MCLOUD_API_KEY" \
		-d "{\"model\":\"$1\",\"max_tokens\":1,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}" \
		"$BASE_URL/chat/completions"
}

fail=0
printf '%-30s %-8s %-6s %s\n' MODEL LISTED PROBE 'PINNED IN'
while read -r id; do
	[ -n "$id" ] || continue
	where="$(printf '%s' "$pins" | awk -F'\t' -v i="$id" '$1==i {print $2}' | sort -u | paste -sd, -)"
	if printf '%s\n' "$served" | grep -qxF "$id"; then
		listed=yes
		code="$(probe "$id")"
		# 429 came from the model's own endpoint, so the id routes and the
		# pin is sound; the throttle is this script's own fault for asking.
		# 503 is the listed-but-backed-by-nothing case.
		case "$code" in
		200 | 429) ;;
		*) fail=1 ;;
		esac
	else
		listed=NO
		code=skip
		fail=1
	fi
	printf '%-30s %-8s %-6s %s\n' "$id" "$listed" "$code" "$where"
done <<<"$ids"

# Served but nothing points at it. Not a failure, just the other half of the
# picture when picking a model.
unpinned="$(comm -23 <(printf '%s\n' "$served") <(printf '%s\n' "$ids") | paste -sd' ' -)"
[ -n "$unpinned" ] && echo && echo "served, unpinned: $unpinned"

if [ "$fail" -ne 0 ]; then
	echo
	echo "mcloud-pins: a pinned model is missing or not answering" >&2
	exit 1
fi
