#!/usr/bin/env bash
# Claude Code SessionStart and PreCompact hook for sessions in a ticket
# worktree (mammoth/MOTHOPS-499/..., or a branch named for the ticket) whose
# ticket has notes under ~/work/tickets/<ID>/.
#
# SessionStart: puts the notes dir, its newest files and the newest status
# doc in context, so a session needn't be pointed at them.
# PreCompact: appends the note given to /compact to the day's
# <date>-claudes-notes.md, the ticket's append-only working log.

set -euo pipefail

input=$(cat)
cwd=$(jq -r '.cwd // empty' <<<"$input")

id=$(grep -oE '\b[A-Z][A-Z0-9]+-[0-9]+\b' <<<"$cwd" | tail -1 || true)
if [ -z "$id" ]; then
	branch=$(git -C "$cwd" branch --show-current 2>/dev/null || true)
	id=$(grep -oiE '\b[a-z][a-z0-9]+-[0-9]+\b' <<<"$branch" | head -1 | tr '[:lower:]' '[:upper:]' || true)
fi
[ -n "$id" ] || exit 0
dir="$HOME/work/tickets/$id"
[ -d "$dir" ] || exit 0

case "$(jq -r '.hook_event_name' <<<"$input")" in
SessionStart)
	{
		printf 'This session works ticket %s. Its notes dir is ~/work/tickets/%s/, newest first:\n' "$id" "$id"
		find "$dir" -mindepth 1 -maxdepth 1 -printf '%T@ %f\n' | sort -rn | head -15 | cut -d' ' -f2- | sed 's/^/  /'
		# Status docs are named <date>-status.md, so the last in glob order
		# is the newest.
		status=''
		for f in "$dir"/*-status.md; do
			[ -e "$f" ] && status=$f
		done
		if [ -n "$status" ]; then
			printf '\nHead of %s:\n' "${status/#$HOME/\~}"
			head -40 "$status"
		fi
	} | head -c 6000 |
		jq -Rs '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: .}}'
	;;
PreCompact)
	note=$(jq -r '.custom_instructions // empty' <<<"$input")
	[ -n "$note" ] || exit 0
	log="$dir/$(date +%F)-claudes-notes.md"
	[ -f "$log" ] || printf "# Claude's working notes -- %s\n" "$(date +%F)" >"$log"
	printf '\n## Compact: %s\n\n%s\n' "$(date +%H:%M)" "$note" >>"$log"
	# PreCompact stdout steers the compaction summary.
	printf 'Keep the ticket ID %s and its notes dir ~/work/tickets/%s/ in the summary.\n' "$id" "$id"
	;;
esac
