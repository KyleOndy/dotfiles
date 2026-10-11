# shellcheck shell=bash
# shellcheck disable=SC2016 # backticks in printf formats are Markdown fences
# writeShellApplication provides the shebang and `set -euo pipefail`; this
# file is only the body (../pi-advisor.nix).
#
# pi-advisor alerts|sweep
#
#   alerts  triage each alert Alertmanager has not been seen firing before
#   sweep   the daily log and metrics reviews
#
# Each run writes one Markdown report to $STATE_DIRECTORY/reports. The unit
# supplies STATE_DIRECTORY, CREDENTIALS_DIRECTORY, PI_CODING_AGENT_DIR (also
# $HOME), PI_ADVISOR_ASSETS (this directory in the store),
# PI_ADVISOR_SETTINGS, PI_ADVISOR_ACKS (Kyle's acknowledged issues) and the
# PI_ADVISOR_*_URL endpoints.

readonly REPORTS="${STATE_DIRECTORY}/reports"
# "<fingerprint> <startsAt>" per line: an alert that resolves and fires again
# gets a new startsAt, and with it a new triage.
readonly SEEN="${STATE_DIRECTORY}/seen-alerts"
# An alert storm is one report per group (see triage_alerts), so these bound
# what one costs. A group past the per-run cap waits for the next run; past
# the daily cap it is marked seen and never triaged.
readonly MAX_ALERTS_PER_RUN=3
readonly MAX_ALERT_REPORTS_PER_DAY=20
readonly RUN_TIMEOUT=15m
# A mistaken paste into the acknowledgements file should not fill the
# model's context.
readonly MAX_ACKS_CHARS=20000

system_prompt=$(<"${PI_ADVISOR_ASSETS}/system.md")
readonly system_prompt

# Kyle writes the acknowledgements, so they go with the task he also wrote,
# never among the untrusted data the tools return. The task and not the
# system prompt: the model works through its task's steps, and reported
# acknowledged issues anyway when they sat at the end of the system prompt.
acks=""
if [[ -s $PI_ADVISOR_ACKS ]]; then
	acks=$'\n\n## Acknowledged issues (Kyle\'s list)\n\n'
	acks+=$(head -c "$MAX_ACKS_CHARS" "$PI_ADVISOR_ACKS")
fi
readonly acks

mkdir -p "$REPORTS" "$PI_CODING_AGENT_DIR"
ln -sf "${CREDENTIALS_DIRECTORY}/models.json" "${PI_CODING_AGENT_DIR}/models.json"
ln -sf "${CREDENTIALS_DIRECTORY}/seats" "${HOME}/seats"
# A copy, since pi writes its settings file.
install -m 0644 "$PI_ADVISOR_SETTINGS" "${PI_CODING_AGENT_DIR}/settings.json"

# Fails on a seat pi would run at another level than it names, or that is
# off mcloud or the catalog, all of which pi would otherwise accept quietly.
# Its messages never name the model, which is also why no report header
# does: the ids are private, and reports go out by mail.
pi-seats check --deploy >/dev/null
MODEL=$(pi-seats get PI_SESSION_MODEL)
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
	--extension "${PI_ADVISOR_ASSETS}/tools.ts"
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

	usage=$(grep -m 1 '^pi-advisor usage: ' "${work}.err" || true)
	rm -f "${work}.err"
	mv "${work}.tmp" "${REPORTS}/${file}"
	echo "wrote ${REPORTS}/${file} (pi exit ${status}) ${usage#pi-advisor }"
}

triage_alerts() {
	local firing group name today count n=0
	firing=$(curl -fsS --max-time 30 \
		"${PI_ADVISOR_AM_URL}/api/v2/alerts?active=true&silenced=false&inhibited=false")
	today=$(date -u +%Y%m%d)
	touch "$SEEN"

	# One triage per group of unseen alerts from one rule on one host that
	# started in the same evaluation. Those most likely share a cause: four
	# calendars failing at once, for one, were four identical triages.
	while IFS= read -r group; do
		((n < MAX_ALERTS_PER_RUN)) || continue

		# Marked before the run, so one that fails or times out is not retried
		# every two minutes at the provider's expense.
		jq -r '.[] | "\(.fingerprint) \(.startsAt)"' <<<"$group" >>"$SEEN"

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
				"$(<"${PI_ADVISOR_ASSETS}/alert.md")" \
				"$(jq 'map({labels, annotations, startsAt})' <<<"$group")" \
				"$acks")"
		n=$((n + 1))
	done < <(jq -c --rawfile seen "$SEEN" '
		($seen | split("\n") | map({(.): true}) | add // {}) as $s
		| map(select($s["\(.fingerprint) \(.startsAt)"] | not))
		| group_by([.labels.alertname, .labels.host, .startsAt])
		| .[]' <<<"$firing")

	# The file keeps only what is firing now, so it stays the size of the
	# current alert set. An alert that is silenced and then unsilenced is
	# triaged again.
	jq -r '.[] | "\(.fingerprint) \(.startsAt)"' <<<"$firing" |
		grep -xFf - "$SEEN" >"${SEEN}.new" || true
	mv "${SEEN}.new" "$SEEN"
}

sweep() {
	local kind
	for kind in logs metrics; do
		advise "sweep-${kind}" \
			"# Daily ${kind} sweep, $(date -u +%F)" \
			"$(<"${PI_ADVISOR_ASSETS}/sweep-${kind}.md")${acks}"
	done
}

case "${1:-}" in
alerts) triage_alerts ;;
sweep) sweep ;;
*)
	echo "usage: pi-advisor alerts|sweep" >&2
	exit 64
	;;
esac
