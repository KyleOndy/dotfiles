# shellcheck shell=bash
# writeShellApplication provides the shebang and `set -euo pipefail`; this
# file is only the body (nix/pkgs/kagi/default.nix).

readonly api="https://kagi.com/api/v1"

# https://kagi.com/api/pricing: search is $12/1k requests, extract is $4/1k
# pages. Search bills per request whatever `limit` asks for; extract bills per
# url whether or not they arrive in one request. Held in mills ($0.001) so the
# running total stays integer arithmetic.
readonly search_mills=12
readonly extract_mills=4

# Read back by extensions/kagi-cost.ts, which folds the amount into pi's
# session cost. Keep the format in step with the regex there.
billed() {
	printf 'kagi: billed $%d.%03d\n' $(($1 / 1000)) $(($1 % 1000)) >&2
}

usage() {
	cat >&2 <<-'EOF'
		usage: kagi search <query> [count]   web search, default 10 results
		       kagi read <url>...            pages as markdown, 10 per request
	EOF
	exit 64
}

# The key travels in a --config stanza on stdin rather than a -H argument,
# because argv is world-readable through ps for the life of the call. That
# takes stdin, so the request body has to arrive as a file.
post() {
	local path=$1 body=$2 out
	if [[ -z ${KAGI_API_KEY:-} ]]; then
		echo "kagi: KAGI_API_KEY is unset" >&2
		exit 78
	fi
	# `if !` rather than a bare assignment: errexit would abort the script at
	# a failing assignment and never reach the handler.
	if ! out=$(
		curl -sS --fail-with-body -m 60 \
			--data-binary "@$body" \
			-H "Content-Type: application/json" \
			--config - <<-EOF
				url = "$api/$path"
				header = "Authorization: Bearer $KAGI_API_KEY"
			EOF
	); then
		local reason
		# The live API answers with `errors`; the published OpenAPI schema says
		# `error`. Read both so a fix on either side does not blank the reason.
		reason=$(jq -r '[.errors[]?, .error[]? | .message // .msg] | join("; ")' <<<"$out" 2>/dev/null) || reason=""
		echo "kagi: $path failed${reason:+: $reason}" >&2
		exit 1
	fi
	printf '%s' "$out"
}

body=$(mktemp)
trap 'rm -f "$body"' EXIT

case ${1:-} in
search)
	[[ -n ${2:-} ]] || usage
	# One request returns whatever a single upstream pass found, ~40 results,
	# and `limit` only truncates that. A second search to see more of the same
	# ranking costs another request; a larger count costs nothing.
	jq -n --arg q "$2" --argjson n "${3:-10}" '{query: $q, limit: $n}' >"$body"
	post search "$body" |
		jq -r '.data.search[]? | "\(.title)\n\(.url)\n\(.snippet // "" | gsub("<[^>]*>"; "") | gsub("\\s+"; " "))\n"'
	billed "$search_mills"
	;;
read)
	shift
	[[ $# -gt 0 ]] || usage
	total=0
	# The endpoint caps a request at 10 urls but bills each one, so batching
	# buys round trips rather than money. Chunking beats rejecting the 11th:
	# the caller would only re-run the command twice for the same price.
	while (($#)); do
		batch=("${@:1:10}")
		shift $(($# < 10 ? $# : 10))
		printf '%s\n' "${batch[@]}" | jq -R '{url: .}' | jq -s '{pages: .}' >"$body"
		# A page the crawler could not reach comes back with markdown null and a
		# per-page error string, which has to read as a failure rather than as an
		# empty page.
		post extract "$body" |
			jq -r '.data[] | "## \(.url)\n\n\(.markdown // "EXTRACTION FAILED: \(.error // "unknown")")\n"'
		total=$((total + extract_mills * ${#batch[@]}))
	done
	billed "$total"
	;;
*)
	usage
	;;
esac
