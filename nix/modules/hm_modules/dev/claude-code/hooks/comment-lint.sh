#!/usr/bin/env bash
# Claude Code PostToolUse hook - flags comments that narrate the edit
# instead of describing the code.
#
# PostToolUse runs after the write lands, so this cannot block. Exit 2 puts
# the finding back in front of the model, which is the only layer that
# survives the regression in anthropics/claude-code#65961: a CLAUDE.md rule
# holds for roughly one turn, then the verbose-comment prior reasserts
# itself. Advisory by design; a false positive costs one rewrite, a missed
# narration comment goes stale forever.
#
# Every pattern below was calibrated against this repo: 158 source files,
# reviewed hit by hit. Anything that fired on a legitimate comment here was
# either narrowed or removed, and the reason is recorded next to it.

set -euo pipefail

# Only comment-bearing source files. Markdown and JSON have no comment
# syntax worth linting, and lock files are generated.
skip_file() {
	case "$1" in
	"" | *.md | *.mdx | *.txt | *.rst | *.json | *.lock | *.csv | *.svg | *.patch | *.diff)
		return 0
		;;
	*)
		return 1
		;;
	esac
}

# The asterisk branches use a character class rather than a backslash
# escape: this regex is also passed to awk via -v, and awk processes escape
# sequences in the value, turning "\*" into a bare "*". That leaves an
# alternation branch that matches the empty string, so every line in the
# file reads as a comment.
readonly COMMENT_START='^[[:space:]]*(#+|//+|;+|--|[*]|/[*])'

# Assembled in pieces because a single-quoted string cannot be continued
# across lines.
#
# Patterns that apply to any comment line. Each is a phrase that describes a
# transition rather than a state.
any=''
any+='(\bno longer\b)|'
any+='(\bpreviously\b)|'
any+='(\bfor now\b)|'
any+='(\bat the moment\b)|'
any+='(\bas of (now|today|this (change|commit|version))\b)|'
# "used to" needs a pronoun subject. The passive "is used to", "can be used
# to" is ordinary description and accounts for more occurrences than the
# narration sense does.
any+='(\b(we|i|it|this|that|they|there)[[:space:]]+used[[:space:]]+to\b)|'
# Bare "currently" describes runtime state as often as code vintage
# ("currently staged", "from a previous run"). Only the capability sense is
# a snapshot smell.
any+='(\bcurrently[[:space:]]+(only|just|still|shells|supports|handles'
any+='|lacks|assumes|hard-?codes|does not|doesn.t|no)\b)|'
any+='(\b(changed|updated|switched|renamed|moved|replaced|refactored'
any+='|reverted|migrated|converted|rewritten)[[:space:]]+'
any+='(to|from|this|it|back|the|into|so)\b)|'
# "one" is excluded from the noun list: "the new one" is usually a runtime
# referent, not a reference to a previous implementation.
any+='(\bthe[[:space:]]+(old|new|previous|original|former)[[:space:]]+'
any+='(implementation|version|approach|code|behaviour|behavior|logic'
any+='|way|method|function|handler|path)\b)'
readonly any

# Patterns that only apply to the first line of a comment block. On a
# wrapped continuation line these words are ordinary prose, so anchoring
# them to the opening line is what keeps the rule honest.
#
# "instead of" is deliberately absent from both sets. It reads as narration
# ("a queue instead of a mutex") but far more often introduces a design
# rationale, which is the most valuable comment there is.
lead=''
lead+="${COMMENT_START}"'[[:space:]]*(now|was)\b|'
# "new", "old" and "fixed" are ordinary adjectives ("new connections",
# "fixed-size buffer"), so they count only as an explicit marker. The
# terminator excludes "-" for the same reason: it matches "fixed-size".
lead+="${COMMENT_START}"'[[:space:]]*(new|old|updated|changed|fixed'
lead+='|added|removed|modified|wip)[[:space:]]*[:!]|'
lead+="${COMMENT_START}"'[[:space:]]*(added|removed|updated|changed'
lead+='|modified|renamed|moved|refactored|reverted|migrated'
lead+='|introduced|deleted)\b'
readonly lead

payload=$(cat)

tool=$(jq -r '.tool_name // ""' <<<"$payload" 2>/dev/null || echo "")
case "$tool" in
Edit | Write | MultiEdit | NotebookEdit) ;;
*) exit 0 ;;
esac

file=$(jq -r '.tool_input.file_path // ""' <<<"$payload" 2>/dev/null || echo "")
if skip_file "$file"; then
	exit 0
fi

# Lint only what this call wrote. Existing comments elsewhere in the file
# are out of scope; the code-comments skill says to leave them alone.
added=$(jq -r '
	[ .tool_input.content?
	, .tool_input.new_string?
	, .tool_input.new_source?
	, (.tool_input.edits[]?.new_string)
	]
	| map(select(type == "string"))
	| join("\n")
' <<<"$payload" 2>/dev/null || echo "")

[ -n "$added" ] || exit 0

# Tag each comment line with whether it opens a block (L) or continues one
# (C), so the lead-anchored rules can be applied to opening lines only.
tagged=$(printf '%s\n' "$added" | awk -v c="$COMMENT_START" '
	{
		is = ($0 ~ c)
		if (is) print (prev ? "C\t" : "L\t") $0
		prev = is
	}
')

[ -n "$tagged" ] || exit 0

mapfile -t offenders < <(
	{
		printf '%s\n' "$tagged" | cut -f2- | grep -iE "$any" || true
		printf '%s\n' "$tagged" | grep '^L' | cut -f2- | grep -iE "$lead" || true
	} |
		sed 's/^[[:space:]]*//' |
		sort -u |
		head -n 10
)

# Volume, which the lexicon check above is blind to. A single global ratio
# would be useless: measured across this repo, the comment share of
# non-blank lines has a median of 0.9% in clojure and 34.6% in shell, so
# one threshold would either scream on every shell edit or never fire on
# clojure. Each ceiling is that language's 90th percentile here, which
# makes the check fire on the top decile of what is already in the tree.
ceiling=25
case "$file" in
*.nix) ceiling=30 ;;
*.sh | *.bash | *.zsh) ceiling=46 ;;
*.clj | *.cljs | *.cljc | *.edn) ceiling=5 ;;
*.lua) ceiling=33 ;;
esac

counts=$(printf '%s\n' "$added" | awk -v c="$COMMENT_START" '
	!/^[[:space:]]*$/ { code++; if ($0 ~ c) cmt++ }
	END { printf "%d %d\n", code + 0, cmt + 0 }
')
code_lines=${counts% *}
comment_lines=${counts#* }

# Below the floor a ratio is noise: one comment on a four-line edit is 25%
# and means nothing.
pct=0
if [ "$code_lines" -ge 15 ]; then
	pct=$((comment_lines * 100 / code_lines))
fi

if [ "${#offenders[@]}" -eq 0 ] && [ "$pct" -le "$ceiling" ]; then
	exit 0
fi

{
	if [ "${#offenders[@]}" -gt 0 ]; then
		printf 'comment-lint: %d comment(s) just written to %s describe the edit rather than the code.\n\n' \
			"${#offenders[@]}" "$file"
		for line in "${offenders[@]}"; do
			n=""
			if [ -f "$file" ]; then
				n=$(grep -nF -m1 -e "$line" -- "$file" 2>/dev/null | cut -d: -f1 || true)
			fi
			printf '  %s:%s  %s\n' "$file" "${n:-?}" "$line"
		done
		cat <<-'EOF'

			Each one fails the tense test: it is not true of the file to a reader who
			has never seen the previous version. Rewrite it as a statement about the
			code as it stands, or delete it.

			  BAD   // changed to a mutex because the old code raced
			  GOOD  // callers may run on the scheduler thread; the mutex guards
			        // against a concurrent flush

			Attribute a constraint to its durable cause (an upstream issue, a
			protocol, a hardware limit), never to the edit that introduced it.
		EOF
	fi

	if [ "$pct" -gt "$ceiling" ]; then
		printf '\ncomment-lint: %d of the %d lines just written to %s are comments (%d%%),\n' \
			"$comment_lines" "$code_lines" "$file" "$pct"
		printf 'against a 90th percentile of %d%% for this language in this repo.\n\n' "$ceiling"
		# Deliberately an instruction and not a question. Asking the model
		# that just wrote the comments whether it wrote too many invites a
		# justification, which is the regression #61305 describes. A bounded
		# re-read produces work instead of an opinion.
		cat <<-'EOF'
			Re-read each comment just added against the deletion test: could someone
			who has never seen this code write that comment from the line next to it?
			Delete every one where the answer is yes. Keep the ones carrying units,
			boundary semantics, ownership, an invariant, or a durable reason.
		EOF
	fi

	printf '\nFull rules: the code-comments skill.\n'
} >&2

exit 2
