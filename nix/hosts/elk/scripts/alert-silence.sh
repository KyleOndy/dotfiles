#!/usr/bin/env bash
set -euo pipefail

ALERTMANAGER_URL="http://127.0.0.1:9093"

usage() {
	cat <<'USAGE'
Usage: alert-silence <command> [options]

Commands:
  add      Create a new silence
  list     List active silences
  expire   Expire (remove) a silence by ID

Add options:
  -a, --alert NAME      Alert name to silence (required)
  -d, --duration DUR    Duration (e.g. 1h, 6h, 1d, 7d) [default: 1d]
  -c, --comment TEXT    Comment [default: "silenced via CLI"]
  -m, --matcher K=V     Extra matcher (can be repeated)

Examples:
  alert-silence add -a SonarrQueueHigh -d 7d -c "large download in progress"
  alert-silence add -a InstanceDown -m job=exportarr-bazarr -d 2h
  alert-silence list
  alert-silence expire abc123
USAGE
	exit 1
}

parse_duration() {
	local dur="$1"
	local num="${dur%[dhm]*}"
	local unit="${dur##*[0-9]}"
	case "$unit" in
	m) echo "$((num * 60))" ;;
	h) echo "$((num * 3600))" ;;
	d) echo "$((num * 86400))" ;;
	*)
		echo "Invalid duration unit: $unit (use m, h, or d)" >&2
		exit 1
		;;
	esac
}

cmd_add() {
	local alert="" duration="1d" comment="silenced via CLI"
	local matchers=()

	while [[ $# -gt 0 ]]; do
		case "$1" in
		-a | --alert)
			alert="$2"
			shift 2
			;;
		-d | --duration)
			duration="$2"
			shift 2
			;;
		-c | --comment)
			comment="$2"
			shift 2
			;;
		-m | --matcher)
			matchers+=("$2")
			shift 2
			;;
		*)
			echo "Unknown option: $1" >&2
			exit 1
			;;
		esac
	done

	if [[ -z $alert ]]; then
		echo "Error: --alert is required" >&2
		exit 1
	fi

	local seconds
	seconds=$(parse_duration "$duration")
	local now ends_at
	now=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
	ends_at=$(date -u -d "+${seconds} seconds" +%Y-%m-%dT%H:%M:%S.000Z)

	# Build matchers JSON array
	local matchers_json
	matchers_json=$(printf '{"name":"alertname","value":"%s","isRegex":false,"isEqual":true}' "$alert")

	for m in "${matchers[@]+"${matchers[@]}"}"; do
		local key="${m%%=*}"
		local val="${m#*=}"
		matchers_json="${matchers_json},$(printf '{"name":"%s","value":"%s","isRegex":false,"isEqual":true}' "$key" "$val")"
	done

	local body
	body=$(printf '{"matchers":[%s],"startsAt":"%s","endsAt":"%s","createdBy":"%s","comment":"%s"}' \
		"$matchers_json" "$now" "$ends_at" "$(whoami)" "$comment")

	local response
	response=$(curl -sf -X POST "${ALERTMANAGER_URL}/api/v2/silences" \
		-H "Content-Type: application/json" \
		-d "$body")

	local sid
	sid=$(echo "$response" | jq -r '.silenceID')
	echo "Silence created: $sid"
	echo "  alert:   $alert"
	echo "  expires: $ends_at"
	echo "  comment: $comment"
}

cmd_list() {
	local silences
	silences=$(curl -sf "${ALERTMANAGER_URL}/api/v2/silences")

	echo "$silences" | jq -r '
    .[] | select(.status.state == "active") |
    "ID:      \(.id)\n" +
    "Matchers: \([.matchers[] | "\(.name)=\(.value)"] | join(", "))\n" +
    "Expires:  \(.endsAt)\n" +
    "Comment:  \(.comment)\n" +
    "---"'

	local count
	count=$(echo "$silences" | jq '[.[] | select(.status.state == "active")] | length')
	echo "$count active silence(s)"
}

cmd_expire() {
	local sid="$1"
	if [[ -z $sid ]]; then
		echo "Error: silence ID required" >&2
		exit 1
	fi
	curl -sf -X DELETE "${ALERTMANAGER_URL}/api/v2/silence/${sid}"
	echo "Silence $sid expired"
}

[[ $# -lt 1 ]] && usage

cmd="$1"
shift
case "$cmd" in
add) cmd_add "$@" ;;
list) cmd_list ;;
expire) cmd_expire "${1:-}" ;;
*) usage ;;
esac
