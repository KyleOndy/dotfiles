---
name: mail-review
description: Review what landed in Junk for kyle@ondy.org and tune mail/ondy.org.sieve. Use for a periodic junk review, a message that went to Junk wrongly, spam that reached the inbox, or a list of senders to unsubscribe from.
---

# Mail review

ondy.org is on MXroute. Filtering has two layers:

- MXroute's SpamAssassin scores every message. At `required=8.0` it is
  flagged, at 15 or more it is rejected and never reaches a folder. The
  weights are MXroute's and are not adjustable: plain HTML mail picks up
  `HTML_MESSAGE` 1.5 and `MIME_HTML_ONLY` 2.0, so legitimate receipts
  and school notices land at 8.x. mxpanel exposes only the rejection
  score, Expert Spam Filtering, and a domain whitelist kept empty.
- `mail/ondy.org.sieve` runs at delivery: keep rules, then junk rules,
  then flagged mail to Junk. It is the only lever. It is git-crypt
  encrypted because it lists who bypasses Junk.

## Run

1. `notmuch new` to sync (its preNew hook runs `mbsync --all`).
2. `python3 mail/review.py --since YYYY-MM-DD`, defaulting to 30 days.
   The output names senders and subjects: read it, never write it into
   the repo.

## Decide

Start from the smallest change. Kyle prefers unsubscribing or changing a
site's notification settings over adding a filter.

- **Junk from senders he otherwise keeps**: a keep rule. Exact address
  over domain; a domain only when the sender uses several addresses.
  Recurring mail only, never for a one-off.
- **Marketing in Junk**: it belongs in the inbox, where he unsubscribes.
  Ask before adding a keep rule for it.
- **Spam reaching the inbox**: a junk rule only for a pattern SpamAssassin
  keeps missing.
- **Keep rule with no rescue in 12 months** (the report flags it): a
  candidate for removal. A rule added recently has no rescues yet.
- **Unsubscribe candidates**: hand Kyle the list. Do not filter them.

Propose the edits with the counts behind each, and wait for agreement.

## Apply

1. Edit `mail/ondy.org.sieve`.
2. Validate without changing the server:
   `pass show email/kyle@ondy.org | head -1 | nix run --inputs-from . nixpkgs#sieve-connect -- --server london.mxroute.com --user kyle@ondy.org --passwordfd 0 --localsieve mail/ondy.org.sieve --checkscript`
3. Kyle runs `make sieve-push`.
4. Commit as `fix(mail): ...`. The repo is public and the commit body is
   not encrypted: give counts and the reason, never sender addresses,
   domains, or subjects.
