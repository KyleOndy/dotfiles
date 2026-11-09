#!/usr/bin/env bash
# Claude Code PreToolUse hook: checks text on its way to other people (a PR,
# a review comment, a commit, a Linear ticket, Slack, Notion) before it
# leaves. A finding denies the call and the reason goes back to the model,
# which rewrites and retries, so the personal-prose rules hold without Kyle
# naming the skill every time.
#
# Fails open: any error exits non-zero without printing a decision, and
# Claude Code runs the call.

set -euo pipefail

readonly SKILL="$HOME/.claude/skills/personal-prose/SKILL.md"
# The two ways a skill reaches a transcript: the Skill tool call, and the
# text a typed /personal-prose expands to.
readonly SKILL_LOADED='"skill":"personal-prose"|Base directory for this skill: [^"]*/personal-prose'

input=$(cat)
tool=$(jq -r '.tool_name' <<<"$input")
cwd=$(jq -r '.cwd // empty' <<<"$input")
findings=()
commits=false

# Whether the command runs $1 as a command, not merely mentions it, as
# `grep 'gh pr create'` would. Leading VAR=value assignments are skipped.
runs() {
	grep -qE "(^|[;&|(\`])[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*($1)" <<<"$cmd"
}

# Prose only: fenced blocks, inline code, URLs and paths removed.
# shellcheck disable=SC2016 # the backticks are markdown, not substitution
prose_of() {
	awk '/^[[:space:]]*(```|~~~)/ { fence = !fence; next } !fence' |
		sed -E 's/`[^`]*`//g; s#https?://[^[:space:])>"]+##g; s#(^|[[:space:]])[~.]?/[^[:space:]]+#\1#g'
}

# Heredoc bodies in a command, where a PR body written in the same command
# lives. Only the ones that are text: fed to $(cat), to --body-file -, or
# written to a .md file. A heredoc fed to bash or python is code.
heredocs() {
	awk '
		!delim && match($0, /<<-?[[:space:]]*["\047]?[A-Za-z_]+["\047]?/) {
			delim = substr($0, RSTART, RLENGTH)
			gsub(/^<<-?[[:space:]]*|["\047]/, "", delim)
			keep = $0 ~ /\$\(cat[[:space:]]*<</ || $0 ~ /(--body-file|-F)[[:space:]]+-[[:space:]]/ ||
				$0 ~ /cat[[:space:]].*\.md([[:space:]]|$)/
			next
		}
		delim && $0 ~ "^[[:space:]]*" delim "[[:space:]]*$" { delim = ""; next }
		delim && keep
	'
}

if [ "$tool" = Bash ]; then
	cmd=$(jq -r '.tool_input.command // empty' <<<"$input")
	runs 'git( -C [^ ]+)? commit( |$)' && commits=true
	if runs 'gh (pr (create|edit|comment|review)|issue (create|edit|comment))( |$)' ||
		{ runs 'gh api ' && grep -qE '/(comments|replies|reviews)' <<<"$cmd" && grep -qF body <<<"$cmd"; }; then
		kind=github
	elif runs 'linear (issue|i) (create|update|comment)( |$)|linear (project-update|pu|document|docs|doc) '; then
		kind=linear
	elif $commits; then
		kind=commit
	else
		exit 0
	fi

	# The directory the command runs in: a leading `cd`, then `git -C`.
	dir=$(sed -nE '1s/^[[:space:]]*cd[[:space:]]+([^;&|[:space:]]+).*/\1/p' <<<"$cmd" | tr -d "\"'")
	[ -n "$dir" ] || dir=$(sed -nE 's/.*git[[:space:]]+-C[[:space:]]+([^[:space:]]+).*/\1/p' <<<"$cmd" | head -1 | tr -d "\"'" || true)
	dir=${dir/#\~/$HOME}
	case "$dir" in
	/*) ;;
	*) dir="$cwd/${dir:-.}" ;;
	esac

	# Body files: gh --body-file/-F, git commit -F/--file, gh api body=@file.
	# body is the text alone, without the shell around it.
	text=$cmd
	body=$(heredocs <<<"$cmd")
	while IFS= read -r f; do
		f=$(tr -d "\"'" <<<"$f")
		f=${f/#\~/$HOME}
		case "$f" in
		"" | -) continue ;;
		/*) ;;
		*) f="$dir/$f" ;;
		esac
		if [ -f "$f" ] && [ "$(wc -c <"$f")" -lt 1000000 ]; then
			text+=$'\n'$(cat "$f")
			body+=$'\n'$(cat "$f")
		fi
	done < <(
		grep -oE -- '(--body-file|--file|-F)[= ]+[^ ;&|)]+' <<<"$cmd" | sed -E 's/^(--body-file|--file|-F)[= ]+//'
		grep -oE 'body=@[^ ;&|)]+' <<<"$cmd" | sed 's/^body=@//'
	)

	has_prose=false
	grep -qE -- '(^|[[:space:]])(--body(-file)?|-b|-F|--title|-t|--description|-d|--fill)([[:space:]=]|$)|body=' <<<"$cmd" && has_prose=true

	if $commits; then
		branch=$(git -C "$dir" branch --show-current 2>/dev/null || true)
		origin=$(git -C "$dir" remote get-url origin 2>/dev/null || true)
		if [[ $branch =~ ^(main|master)$ && $origin =~ [:/]modularml/ ]]; then
			findings+=("This commits on $branch in a modularml repo. Work goes on a branch in a ticket worktree.")
		fi
	fi

	if runs 'gh pr create( |$)' && ! grep -qE '[[:space:]](--draft|-d)([[:space:]=]|$)' <<<"$cmd"; then
		findings+=("Open the PR as a draft (--draft). Kyle marks it ready, or approves gh pr ready, once he has read it.")
	fi
elif [[ $tool == mcp__* ]]; then
	kind=mcp
	has_prose=true
	# Only the fields holding new text. IDs and commands are not prose, and
	# Notion's old_str and selection_with_ellipsis quote the page as it
	# stands. A blank line between fields keeps one from reading as the
	# wrapped continuation of another.
	text=$(jq -r '
		[.tool_input | .. | objects | to_entries[]
			| select(.key | test("^(new_str|content|markdown|message|text|body|description|title)$"; "i"))
			| .value | strings]
		| join("\n\n")
	' <<<"$input")
	body=$text
else
	exit 0
fi

if $has_prose && [ "$kind" != commit ]; then
	transcript=$(jq -r '.transcript_path // empty' <<<"$input")
	agent=$(jq -r '.agent_id // empty' <<<"$input")
	# A subagent has its own context, so the main session loading the skill
	# does not put it in front of the subagent.
	if [ -n "$agent" ] && [ -f "${transcript%.jsonl}/subagents/agent-$agent.jsonl" ]; then
		transcript="${transcript%.jsonl}/subagents/agent-$agent.jsonl"
	fi
	if [ -f "$transcript" ] && ! grep -qE "$SKILL_LOADED" "$transcript"; then
		findings+=("The personal-prose skill is not loaded in this session. Load it with the Skill tool and check the text against it, short, direct and concise.")
	fi
fi

prose=$(prose_of <<<"$text")

hits=$(grep -F -e '—' -e ' – ' <<<"$prose" | cut -c1-100 | head -2 || true)
if [ -n "$hits" ]; then
	findings+=("Em or en dash used as a dash. Use a comma or a new sentence:"$'\n'"$hits")
fi

# UTF-8 lead bytes of U+1F000-1FFFF and U+2600-27BF, the emoji and dingbat
# blocks, matched bytewise so the check does not depend on the locale.
if LC_ALL=C grep -qP '\xF0\x9F|\xE2[\x98-\x9E]' <<<"$prose"; then
	findings+=("Emoji or dingbat in the text. Drop it.")
fi

if [ "$kind" != commit ] && ! $commits; then
	# GitHub, Slack and Notion render a single newline inside a paragraph as
	# a line break, so a wrapped paragraph shows up ragged. A long line with
	# no closing punctuation followed by one starting lowercase is a wrap.
	# A YAML key, or a line with a run of spaces inside it (a directory tree,
	# aligned columns), is layout outside a fence, not prose.
	wraps=$(awk '
		function layout(s) { return s ~ /^[[:space:]]*[A-Za-z_][A-Za-z0-9_-]*:/ || s ~ /[^ ]  +[^ ]/ }
		/^[[:space:]]*(```|~~~)/ { fence = !fence; prev = ""; next }
		fence { next }
		prev != "" && $0 ~ /^[[:space:]]*[a-z(]/ && !layout($0) { print "  " prev " / " $0; n++ }
		{ prev = (length($0) >= 30 && $0 !~ /^[[:space:]]*[#|<]/ && $0 !~ /[.!?:]$|  $|\\$/ && !layout($0)) ? $0 : "" }
		n >= 2 { exit }
	' <<<"$body" | cut -c1-160)
	if [ -n "$wraps" ]; then
		findings+=("Hard-wrapped paragraph. One paragraph per line:"$'\n'"$wraps")
	fi
fi

if [ "$kind" = github ] && grep -qiE '^(#+[[:space:]]*|\*\*)(test plan|testing)\b' <<<"$text"; then
	findings+=("Drop the test plan or testing section from the body.")
fi

if [ -r "$SKILL" ]; then
	# The skill's two lists, minus the words marked (metaphorical). A trailing
	# e is dropped and inflections allowed back, so leveraging and utilized
	# match but utilization, a metric, does not.
	stems=$(awk '/^\*\*Banned (words|transitions):\*\*/ { on = 1 } on && /^$/ { on = 0 } on' "$SKILL" |
		sed -E 's/\*\*[^*]+\*\*//' | tr '\n.' ' ,' | tr ',' '\n' |
		sed -E 's/^[[:space:]]+|[[:space:]]+$//g' | grep -v '(' | grep -v '^$' |
		sed -E 's/e$//' | paste -sd '|' - || true)
	if [ -n "$stems" ]; then
		words=$(grep -oiwE "($stems)(e|es|ed|ely|ing|s|ly|d)?" <<<"$prose" | tr '[:upper:]' '[:lower:]' | sort -u | paste -sd ',' - | sed 's/,/, /g' || true)
		if [ -n "$words" ]; then
			findings+=("Banned by personal-prose: $words.")
		fi
	fi
fi

[ ${#findings[@]} -gt 0 ] || exit 0

reason="prose-gate refused this $tool call. Fix each finding, then retry."
for f in "${findings[@]}"; do
	reason+=$'\n'"- $f"
done

jq -n --arg r "$reason" '{
	hookSpecificOutput: {
		hookEventName: "PreToolUse",
		permissionDecision: "deny",
		permissionDecisionReason: $r
	}
}'
