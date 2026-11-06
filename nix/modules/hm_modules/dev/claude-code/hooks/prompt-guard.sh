#!/usr/bin/env bash
# Claude Code UserPromptSubmit hook. Keeps a YubiKey OTP or a credential from
# reaching the model, and notes personal-prose on a prompt that asks for text
# other people will read, which Kyle otherwise types as a tail on the prompt.

set -euo pipefail

prompt=$(jq -r '.prompt // ""')

block() {
	jq -n --arg r "$1" '{decision: "block", reason: $r}'
	exit 0
}

# A touch of the key types its 44-character modhex OTP and presses Enter.
if grep -qxE '[[:space:]]*[cbdefghijklnrtuv]{44}[[:space:]]*' <<<"$prompt"; then
	block "Not sent: that looks like a YubiKey OTP."
fi

# Provider token formats. An AWS key ID alone is not a secret, so it counts
# only next to something shaped like its 40-character secret, which is
# base64 and so mixes cases, unlike a hex git SHA of the same length.
secret=''
if grep -qE '(gh[pousr]_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{50,}|sk-ant-[A-Za-z0-9_-]{20,}|sk-(proj-)?[A-Za-z0-9_-]{40,}|xox[abpr]-[A-Za-z0-9-]{10,}|lin_api_[A-Za-z0-9]{30,}|glpat-[A-Za-z0-9_-]{20})' <<<"$prompt"; then
	secret='an API token'
elif grep -qE -e '-----BEGIN [A-Z ]*PRIVATE KEY-----' <<<"$prompt"; then
	secret='a private key'
elif grep -qE '(AKIA|ASIA)[0-9A-Z]{16}' <<<"$prompt" &&
	grep -oE '(^|[^A-Za-z0-9/+])[A-Za-z0-9/+]{40}([^A-Za-z0-9/+]|$)' <<<"$prompt" | grep '[A-Z]' | grep '[a-z]' >/dev/null; then
	secret='an AWS access key pair'
fi
if [ -n "$secret" ]; then
	block "Not sent: the prompt holds what looks like $secret. Secrets stay in sops; refer to one by its name or path."
fi

case "$prompt" in
/*) exit 0 ;;
esac
if grep -qiwE 'prs?|pull request|commit message|slack|reply|respond|response|draft|ticket|linear|notion|comments?|readme|docs?|email|post|rephrase|reword|rewrite|wording|concise|shorter|terse|tighten|wordy|fluff|ai-?isms?' <<<"$prompt"; then
	jq -n '{
		hookSpecificOutput: {
			hookEventName: "UserPromptSubmit",
			additionalContext: "The personal-prose skill covers any text drafted this turn for someone else to read: PR bodies and review comments, commit bodies, Linear tickets, Slack, Notion. Its default is short, direct and concise. The prose-gate hook refuses gh, linear, Slack and Notion writes until the skill is loaded in the session."
		}
	}'
fi
