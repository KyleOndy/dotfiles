# shellcheck shell=bash
# writeShellApplication provides the shebang and `set -euo pipefail`; this
# file is only the body (nix/pkgs/mail-stragglers/default.nix).
#
# Lists who still mails ondy.me and kyleondy@gmail.com, then opens pi with
# Kagi search to find how to move each one to ondy.org. Trex-only: the
# maildirs live here. Delete this package once the list comes back empty.
#
#   mail-stragglers [--days N]          list, then work through it in pi
#   mail-stragglers --list [--days N]   list only

list_only=no
if [ "${1:-}" = "--list" ]; then
	list_only=yes
	shift
fi
readonly list_only

report=$(python3 "$MAIL_STRAGGLERS_PY" "$@")
if [ -z "$report" ]; then
	echo "Nothing but people has mailed ondy.me or kyleondy@gmail.com in that window."
	exit 0
fi
printf '%s\n' "$report"
if [ "$list_only" = yes ]; then
	exit 0
fi

instructions=$(
	cat <<'EOF'
Kyle is retiring two email addresses and moving every account to ondy.org:

- ondy.me, a catch-all domain. It lapses on 2027-08-13, and after that
  whoever registers it receives mail for every address on it, password
  resets included. Each local part (navirefi@, roku@) is the one address
  that service knows him by.
- kyleondy@gmail.com.

The first message lists every sender that mailed either address in the
window: sending domain, message count, last seen, which retired address it
reached, and the latest subject. "(ondy.me)" means Bcc or list mail that
landed in that mailbox without naming the address. People are filtered out
before this list, so every row is a company, a list, or spam. Services whose
email change was confirmed with nothing to a retired address since are
filtered out too.

A row noting "email change confirmed" still got mail at a retired address
after the change: usually a second account or a marketing list kept apart
from the account. The list at the end is every confirmed change from any
mailbox; a row from another domain of one of those companies is done unless
its last-seen date is later.

1. Classify every domain: an account to move, a mailing list to
   resubscribe from ondy.org, marketing to unsubscribe from, spam or
   phishing to ignore, or nothing to do. Merge domains that belong to the
   same company. Japanese-language lures on random domains are phishing;
   say so in one line.
2. For each account to move, find the company's own help page for changing
   the account email with kagi search, and confirm it with kagi read.
   Batch the reads. Cite only pages you read; when no official page turns
   up, say so rather than guess.
3. Reply with one checklist, riskiest first: money, government, health and
   account-recovery addresses, then hosting and infrastructure, then
   services that sign in by emailed code, then the rest. One line each:
   service, retired address, help URL, menu path. After it, one line each
   for the unsubscribes and the ignored domains.

Kyle then works through the list with you. Never ask for passwords or
codes.
EOF
)
readonly instructions

# --allow-kagi must come first: the pi wrapper only parses its own flags
# ahead of pi's.
exec pi --allow-kagi --append-system-prompt "$instructions" -- "$report"
