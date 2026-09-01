# shellcheck shell=bash
# writeShellApplication provides the shebang and `set -euo pipefail`; this
# file is only the body (nix/pkgs/kagi/default.nix).

readonly api="https://kagi.com/api/v1"

usage() {
	cat >&2 <<-'EOF'
		usage: kagi search <query> [count]   web search, default 5 results
		       kagi read <url>...            up to 10 pages, as markdown
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
	jq -n --arg q "$2" --argjson n "${3:-5}" '{query: $q, limit: $n}' >"$body"
	post search "$body" |
		jq -r '.data.search[]? | "\(.title)\n\(.url)\n\(.snippet // "" | gsub("<[^>]*>"; "") | gsub("\\s+"; " "))\n"'
	;;
read)
	shift
	[[ $# -gt 0 && $# -le 10 ]] || usage
	printf '%s\n' "$@" | jq -R '{url: .}' | jq -s '{pages: .}' >"$body"
	# A page the crawler could not reach comes back with markdown null and a
	# per-page error string, which has to read as a failure rather than as an
	# empty page.
	post extract "$body" |
		jq -r '.data[] | "## \(.url)\n\n\(.markdown // "EXTRACTION FAILED: \(.error // "unknown")")\n"'
	;;
*)
	usage
	;;
esac
