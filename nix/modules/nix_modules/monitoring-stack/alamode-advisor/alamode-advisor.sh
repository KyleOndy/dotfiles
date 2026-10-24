# shellcheck shell=bash
# shellcheck disable=SC2016 # backticks in printf formats are Markdown fences
# writeShellApplication provides the shebang and `set -euo pipefail`; this
# file is only the body (../alamode-advisor.nix).
#
# alamode-advisor alerts|sweep
#
#   alerts  triage each alert Alertmanager has not been seen firing before
#   sweep   the daily log, metrics and playback reviews
#
# Each run writes one Markdown report to $STATE_DIRECTORY/reports. The unit
# supplies STATE_DIRECTORY, CREDENTIALS_DIRECTORY, PI_CODING_AGENT_DIR (also
# $HOME), ALAMODE_ADVISOR_ASSETS (this directory in the store),
# ALAMODE_ADVISOR_SETTINGS, ALAMODE_ADVISOR_ACKS (Kyle's acknowledged issues) and the
# ALAMODE_ADVISOR_*_URL endpoints.

readonly REPORTS="${STATE_DIRECTORY}/reports"
# "<fingerprint> <epoch seconds>" per line: each alert already triaged, and
# the last time a run saw it firing.
readonly SEEN="${STATE_DIRECTORY}/seen-alerts"
# How long an alert must go without firing before it next fires as a new
# incident, in seconds. startsAt cannot mark one: a flapping alert gets a new
# one each time it resolves, and a deploy that restarts Alertmanager, which
# holds alerts only in memory, gives every firing alert a new one.
readonly RETRIAGE_AFTER=$((6 * 3600))
# jq: $seen, the file's text, as {fingerprint: epoch}. A line still holding
# a startsAt from before the epoch format reads as seen at $now.
readonly SEEN_MAP='def seen_map: $seen | split("\n") | map(select(length > 0) | split(" ") | {(.[0]): (.[1] | tonumber? // $now)}) | add // {};'
# An alert storm is one report per group (see triage_alerts), so these bound
# what one costs. A group past the per-run cap waits for the next run; past
# the daily cap it is marked seen and never triaged.
readonly MAX_ALERTS_PER_RUN=3
readonly MAX_ALERT_REPORTS_PER_DAY=20
readonly RUN_TIMEOUT=15m
# A mistaken paste into the acknowledgements file should not fill the
# model's context.
readonly MAX_ACKS_CHARS=20000

system_prompt=$(<"${ALAMODE_ADVISOR_ASSETS}/system.md")
readonly system_prompt

# Kyle writes the acknowledgements, so they go with the task he also wrote,
# never among the untrusted data the tools return. The task and not the
# system prompt: the model works through its task's steps, and reported
# acknowledged issues anyway when they sat at the end of the system prompt.
acks=""
if [[ -s $ALAMODE_ADVISOR_ACKS ]]; then
	acks=$'\n\n## Acknowledged issues (Kyle\'s list)\n\n'
	acks+=$(head -c "$MAX_ACKS_CHARS" "$ALAMODE_ADVISOR_ACKS")
fi
readonly acks

mkdir -p "$REPORTS" "$PI_CODING_AGENT_DIR"
ln -sf "${CREDENTIALS_DIRECTORY}/models.json" "${PI_CODING_AGENT_DIR}/models.json"
ln -sf "${CREDENTIALS_DIRECTORY}/seats" "${HOME}/seats"
# A copy, since pi writes its settings file.
install -m 0644 "$ALAMODE_ADVISOR_SETTINGS" "${PI_CODING_AGENT_DIR}/settings.json"

# Fails on a seat pi would run at another level than it names, or that is
# off mcloud or the catalog, all of which pi would otherwise accept quietly.
# Its messages never name the model, which is also why no report header
# does: the ids are private, and reports go out by mail.
alamode-seats check --deploy >/dev/null
MODEL=$(alamode-seats get ALAMODE_SESSION_MODEL)
readonly MODEL

readonly PI_ARGS=(
	--print
	--no-session
	--offline
	--no-extensions
	--no-skills
	--no-context-files
	--no-prompt-templates
	--no-themes
	--no-approve
	--extension "${ALAMODE_ADVISOR_ASSETS}/tools.ts"
	--tools "promql,logql,baseline,metric_labels,log_labels,alerts,alert_rules,web_search"
	--model "$MODEL"
	--system-prompt "$system_prompt"
)

MCLOUD_API_KEY=$(<"${CREDENTIALS_DIRECTORY}/mcloud")
KAGI_API_KEY=$(<"${CREDENTIALS_DIRECTORY}/kagi")
export MCLOUD_API_KEY KAGI_API_KEY

slug() {
	printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-80
}

# advise <name> <header> <task>
advise() {
	local name="$1" header="$2" task="$3"
	local file work status=0 usage
	file="$(date -u +%Y%m%dT%H%M%SZ)-${name}.md"
	# Built outside the reports directory, so the only change the mailer's
	# path unit sees there is the finished report arriving.
	work="${STATE_DIRECTORY}/${file}"

	{
		printf '%s\n\n' "$header"
		# pi reads a non-TTY stdin to its end and adds it to the prompt, and the
		# caller's stdin may be the rest of the alert list.
		timeout "$RUN_TIMEOUT" pi "${PI_ARGS[@]}" "$task" </dev/null 2>"${work}.err" || status=$?
		if ((status != 0)); then
			printf '\n\npi exited %d:\n\n```\n%s\n```\n' "$status" "$(tail -c 4000 "${work}.err")"
		fi
	} >"${work}.tmp"

	usage=$(grep -m 1 '^alamode-advisor usage: ' "${work}.err" || true)
	grep '^alamode-advisor tool-error: ' "${work}.err" >&2 || true
	rm -f "${work}.err"
	mv "${work}.tmp" "${REPORTS}/${file}"
	echo "wrote ${REPORTS}/${file} (pi exit ${status}) ${usage#alamode-advisor }"
}

triage_alerts() {
	local firing group name today now count n=0
	firing=$(curl -fsS --max-time 30 \
		"${ALAMODE_ADVISOR_AM_URL}/api/v2/alerts?active=true&silenced=false&inhibited=false")
	today=$(date -u +%Y%m%d)
	now=$(date +%s)
	touch "$SEEN"

	# One triage per group of unseen alerts from one rule on one host that
	# started in the same evaluation. Those most likely share a cause: four
	# calendars failing at once, for one, were four identical triages.
	while IFS= read -r group; do
		((n < MAX_ALERTS_PER_RUN)) || continue

		# Marked before the run, so one that fails or times out is not retried
		# every two minutes at the provider's expense.
		jq -r --arg now "$now" '.[] | "\(.fingerprint) \($now)"' <<<"$group" >>"$SEEN"

		count=$(find "$REPORTS" -name "${today}T*-alert-*.md" | wc -l)
		if ((count >= MAX_ALERT_REPORTS_PER_DAY)); then
			echo "daily cap reached, not triaging $(jq -r '[.[].fingerprint] | join(" ")' <<<"$group")"
			continue
		fi

		# The first fingerprint keeps apart two groups of one name on one host,
		# such as two units that failed minutes apart, triaged in the same
		# second. It goes first so that slug's cut never reaches it.
		name=$(jq -r '.[0] | [.fingerprint, .labels.alertname, .labels.host // empty] | join("-")' <<<"$group")
		advise "alert-$(slug "$name")" \
			"$(jq -r '"# \(.[0].labels.alertname) on \(.[0].labels.host // "-")\(if length > 1 then " (\(length) alerts)" else "" end)\n\nstarted \(.[0].startsAt)"' <<<"$group")" \
			"$(printf '%s\n\n```json\n%s\n```%s\n' \
				"$(<"${ALAMODE_ADVISOR_ASSETS}/alert.md")" \
				"$(jq 'map({labels, annotations, startsAt})' <<<"$group")" \
				"$acks")"
		n=$((n + 1))
	done < <(jq -c --rawfile seen "$SEEN" --argjson now "$now" --argjson gap "$RETRIAGE_AFTER" "${SEEN_MAP}"'
		seen_map as $s
		| map(select(($s[.fingerprint] // 0) < $now - $gap))
		| group_by([.labels.alertname, .labels.host, .startsAt])
		| .[]' <<<"$firing")

	# Each fingerprint in the file that is firing now is stamped now; one not
	# seen firing for RETRIAGE_AFTER is dropped. Only fingerprints already in
	# the file are stamped, so a group held back by MAX_ALERTS_PER_RUN still
	# gets its turn. A silence counts as not firing.
	jq -r --rawfile seen "$SEEN" --argjson now "$now" --argjson gap "$RETRIAGE_AFTER" "${SEEN_MAP}"'
		seen_map as $s
		| $s + (map(select($s[.fingerprint]) | {(.fingerprint): $now}) | add // {})
		| to_entries[]
		| select(.value >= $now - $gap)
		| "\(.key) \(.value)"' <<<"$firing" >"${SEEN}.new"
	mv "${SEEN}.new" "$SEEN"
}

sweep() {
	local kind
	for kind in logs metrics playback; do
		advise "sweep-${kind}" \
			"# Daily ${kind} sweep, $(date -u +%F)" \
			"$(<"${ALAMODE_ADVISOR_ASSETS}/sweep-${kind}.md")${acks}"
	done
}

case "${1:-}" in
alerts) triage_alerts ;;
sweep) sweep ;;
*)
	echo "usage: alamode-advisor alerts|sweep" >&2
	exit 64
	;;
esac
