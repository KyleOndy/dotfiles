# shellcheck shell=bash
# writeShellApplication provides the shebang and `set -euo pipefail`; this
# file is only the body (nix/pkgs/pagerduty/default.nix).

readonly api="${PAGERDUTY_API_URL:-https://api.pagerduty.com}"

usage() {
	cat >&2 <<-'EOF'
		usage: pagerduty [--mine]                    open incidents, newest first
		       pagerduty get <path> [name=value]...  any GET, raw JSON
	EOF
	exit 64
}

need_token() {
	if [[ -z ${PAGERDUTY_TOKEN:-} ]]; then
		PAGERDUTY_TOKEN=$(sh -c "${PAGERDUTY_TOKEN_COMMAND:-true}") || PAGERDUTY_TOKEN=""
	fi
	if [[ -z $PAGERDUTY_TOKEN ]]; then
		echo "pagerduty: no token from ${PAGERDUTY_TOKEN_COMMAND:-<no tokenCommand>}; PAGERDUTY_TOKEN covers a single run" >&2
		exit 78
	fi
}

# Every request is a GET, so a token that can write still only reads here.
# The token travels in a --config stanza on stdin rather than a -H argument,
# because argv is world-readable through ps for the life of the call.
get() {
	local path=$1 out arg query=()
	shift
	for arg in "$@"; do
		query+=(--data-urlencode "$arg")
	done
	if ! out=$(
		curl -sS --fail-with-body -m 30 --proto =https -G \
			--url "$api$path" \
			"${query[@]}" \
			-H "Accept: application/vnd.pagerduty+json;version=2" \
			--config - <<-EOF
				header = "Authorization: Token token=$PAGERDUTY_TOKEN"
			EOF
	); then
		local reason
		reason=$(jq -r '.error | [.message, .errors[]?] | join("; ")' <<<"$out" 2>/dev/null) || reason=""
		echo "pagerduty: GET $path failed${reason:+: $reason}" >&2
		exit 1
	fi
	printf '%s\n' "$out"
}

case ${1:-} in
"" | --mine)
	need_token
	# Without date_range=all the API applies its default one-month window, which
	# hides an incident that has stayed open longer than that.
	query=("statuses[]=triggered" "statuses[]=acknowledged" "date_range=all" "sort_by=created_at:desc" "limit=100")
	if [[ ${1:-} == --mine ]]; then
		# /users/me answers only for a user token, not an account key.
		me=$(get /users/me | jq -r .user.id)
		query+=("user_ids[]=$me")
	fi
	incidents=""
	offset=0
	while :; do
		page=$(get /incidents "${query[@]}" "offset=$offset")
		incidents+=$(jq -c '.incidents[]' <<<"$page")$'\n'
		[[ $(jq -r .more <<<"$page") == true ]] || break
		offset=$((offset + 100))
	done
	jq -rs '
		if length == 0 then "no open incidents" else .[] |
			"\(.id)  #\(.incident_number)  \(.status)  \([.urgency, .priority.summary // empty] | join(" "))  \(.created_at)  \(.service.summary)\n" +
			"  \(.title)\n" +
			"  assigned: \([.assignments[].assignee.summary] | join(", ") | if . == "" then "nobody" else . end)\n" +
			"  \(.html_url)\n"
		end
	' <<<"$incidents"
	;;
get)
	[[ ${2:-} == /* ]] || usage
	need_token
	shift
	get "$@"
	;;
*)
	usage
	;;
esac
