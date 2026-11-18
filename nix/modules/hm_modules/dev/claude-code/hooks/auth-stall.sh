#!/usr/bin/env bash
# Claude Code PostToolUse and PostToolUseFailure hook on Bash: recognizes a
# command that failed on expired or locked credentials, tells the model to
# stop and ask instead of retrying or working around it, and shows Kyle the
# command to run. Only Kyle can log in or touch the YubiKey.

set -euo pipefail

input=$(cat)
event=$(jq -r '.hook_event_name' <<<"$input")
cmd=$(jq -r '.tool_input.command // ""' <<<"$input")
# A non-zero exit fires PostToolUseFailure with the output in .error.
out=$(jq -r '
	(.tool_response | if type == "object" then "\(.stdout // "")\n\(.stderr // "")" else tostring end),
	(.error // "")
' <<<"$input")

# A real error starts its line, after any `word: ` labels (`aws: [ERROR]:`,
# `error:`, `botocore.exceptions.ClientError:`) and mk exec's per-cluster
# prefix. Source and docs that quote these strings indent or quote them, so
# a session reading such a file does not trip the hook.
lead='^([^[:space:]]+ +[^[:alnum:][:space:]]+ )?([^[:space:]]+: )*'

what='' fix=''
if grep -qE "${lead}(An error occurred \(ExpiredToken|Token has expired|(The )?SSO session associated with this profile has expired|Error when retrieving token from sso|Error loading SSO Token)" <<<"$out"; then
	profile=$(grep -oE '(--profile[= ]|AWS_PROFILE=)[A-Za-z0-9_.-]+' <<<"$cmd" | head -1 | sed -E 's/^(--profile[= ]|AWS_PROFILE=)//' || true)
	what='The AWS SSO session expired'
	fix="aws sso login${profile:+ --profile $profile}"
elif grep -qE "${lead}(gpg: signing failed|gpg failed to sign the data|gpg: decryption failed: No secret key|gpg: .*pinentry)" <<<"$out"; then
	what='The gpg agent is locked'
	fix='unlock the YubiKey (any gpg or pass command that prompts)'
elif grep -qE '(^|[;&|(])[[:space:]]*pup ' <<<"$cmd" &&
	grep -qiE '\b(401|403)\b|unauthori[sz]ed|not authenticated|token (is )?expired' <<<"$out"; then
	what='pup is not authenticated'
	fix='pup auth refresh'
elif grep -qE "${lead}(HTTP 401: Bad credentials|To get started with GitHub CLI|Try authenticating with: +gh auth login)" <<<"$out"; then
	what='The gh token is invalid or expired'
	fix='gh auth refresh'
elif grep -qE "${lead}You must be logged in to the server" <<<"$out"; then
	what='The cluster credentials expired'
	fix='aws sso login for an EKS cluster, or re-auth the Rancher one'
fi
[ -n "$what" ] || exit 0

jq -n --arg e "$event" --arg w "$what" --arg f "$fix" '{
	systemMessage: "\($w). Run: \($f)",
	hookSpecificOutput: {
		hookEventName: $e,
		additionalContext: "\($w), so this command failed on credentials, not on its own merits. Only Kyle can fix it (\($f)), and every call that needs it fails the same way until he does. Ask him and wait, rather than retrying or switching tools to get around it."
	}
}'
