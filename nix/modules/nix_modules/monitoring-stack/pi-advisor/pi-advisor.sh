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
# supplies STATE_DIRECTORY, CREDENTIALS_DIRECTORY, PI_CODING_AGENT_DIR,
# PI_ADVISOR_ASSETS (this directory in the store), PI_ADVISOR_ACKS (Kyle's
# acknowledged issues) and the PI_ADVISOR_*_URL endpoints.

readonly MODEL="zai/glm-5.3"
readonly REPORTS="${STATE_DIRECTORY}/reports"
# "<fingerprint> <startsAt>" per line: an alert that resolves and fires again
# gets a new startsAt, and with it a new triage.
readonly SEEN="${STATE_DIRECTORY}/seen-alerts"
# An alert storm is one report per alert, so these bound what one costs. An
# alert past the per-run cap waits for the next run; past the daily cap it is
# marked seen and never triaged.
readonly MAX_ALERTS_PER_RUN=3
readonly MAX_ALERT_REPORTS_PER_DAY=20
readonly RUN_TIMEOUT=15m
# A mistaken paste into the acknowledgements file should not fill the
# model's context.
readonly MAX_ACKS_CHARS=20000

# Kyle writes the acknowledgements, so they belong in the system prompt
# rather than among the untrusted data the tools return.
system_prompt=$(<"${PI_ADVISOR_ASSETS}/system.md")
if [[ -s $PI_ADVISOR_ACKS ]]; then
	system_prompt+=$'\n\n## Acknowledged issues (Kyle\'s list)\n\n'
	system_prompt+=$(head -c "$MAX_ACKS_CHARS" "$PI_ADVISOR_ACKS")
fi
readonly system_prompt

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
	--tools "promql,logql,metric_labels,log_labels,alerts,alert_rules,web_search,read_result"
	--model "$MODEL"
	--thinking high
	--system-prompt "$system_prompt"
)

ZAI_API_KEY=$(<"${CREDENTIALS_DIRECTORY}/zai")
KAGI_API_KEY=$(<"${CREDENTIALS_DIRECTORY}/kagi")
export ZAI_API_KEY KAGI_API_KEY

mkdir -p "$REPORTS" "$PI_CODING_AGENT_DIR"

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
	local firing alert key name today count n=0
	firing=$(curl -fsS --max-time 30 \
		"${PI_ADVISOR_AM_URL}/api/v2/alerts?active=true&silenced=false&inhibited=false")
	today=$(date -u +%Y%m%d)
	touch "$SEEN"

	while IFS= read -r alert; do
		key=$(jq -r '"\(.fingerprint) \(.startsAt)"' <<<"$alert")
		grep -qxF "$key" "$SEEN" && continue
		((n < MAX_ALERTS_PER_RUN)) || continue

		# Marked before the run, so one that fails or times out is not retried
		# every two minutes at the provider's expense.
		echo "$key" >>"$SEEN"

		count=$(find "$REPORTS" -name "${today}T*-alert-*.md" | wc -l)
		if ((count >= MAX_ALERT_REPORTS_PER_DAY)); then
			echo "daily cap reached, not triaging ${key}"
			continue
		fi

		# The fingerprint keeps apart two alerts of one name on one host, such as
		# two failed units, triaged in the same second. It goes first so that
		# slug's cut never reaches it.
		name=$(jq -r '[.fingerprint, .labels.alertname, .labels.host // empty] | join("-")' <<<"$alert")
		advise "alert-$(slug "$name")" \
			"$(jq -r --arg model "$MODEL" \
				'"# \(.labels.alertname) on \(.labels.host // "-")\n\nstarted \(.startsAt), triaged by \($model)"' <<<"$alert")" \
			"$(printf '%s\n\n```json\n%s\n```\n' \
				"$(<"${PI_ADVISOR_ASSETS}/alert.md")" \
				"$(jq '{labels, annotations, startsAt}' <<<"$alert")")"
		n=$((n + 1))
	done < <(jq -c '.[]' <<<"$firing")

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
			"# Daily ${kind} sweep, $(date -u +%F)"$'\n\n'"by ${MODEL}" \
			"$(<"${PI_ADVISOR_ASSETS}/sweep-${kind}.md")"
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
