"""List who still mails the addresses being retired.

Groups recent mail to ondy.me and kyleondy@gmail.com by sending domain.
Services go to stdout, which mail-stragglers.sh hands to pi. People and
services that already confirmed an email change go to stderr, so they reach
the terminal and never the model.

Matching uses the indexed To/Cc plus the two retired mailboxes' own
maildirs, so Bcc and list mail still counts.
"""

import argparse
import json
import re
import subprocess
import sys
from datetime import datetime
from email.utils import getaddresses
from pathlib import Path

MAILDIRS = ("ondy.me", "gmail.com")
SKIP_FOLDERS = {"Junk", "spam", "Spam", "Sent", "Sent Messages", "Send", "Drafts"}

# Subjects saying an account's email was changed or added. Bare "verify your
# email" is left out: nearly all of those are new signups, spam included.
CONFIRMATION = re.compile(
    r"\be-?mail( address)?\b.{0,40}\b(updated|changed|added|change)\b"
    r"|\b(new|updated|changed) e-?mail\b"
    r"|\bchange (of|to) (your )?e-?mail\b",
    re.IGNORECASE,
)

# A confirmation counts only when it went to ondy.org or names it. Notices
# about the move onto ondy.me years ago match the subject pattern too.
CONFIRMATION_QUERY = '(subject:email or subject:e-mail) and (to:ondy.org or "ondy.org")'

# Senders on these domains are people, not services.
FREEMAIL = {
    "aol.com",
    "comcast.net",
    "gmail.com",
    "googlemail.com",
    "hotmail.com",
    "icloud.com",
    "live.com",
    "mac.com",
    "me.com",
    "optonline.net",
    "outlook.com",
    "proton.me",
    "protonmail.com",
    "verizon.net",
    "yahoo.com",
}


def is_old(addr):
    return addr.endswith("@ondy.me") or addr == "kyleondy@gmail.com"


def is_self(addr):
    return is_old(addr) or addr.endswith("@ondy.org")


def sender_key(addr):
    domain = addr.rpartition("@")[2]
    if domain in FREEMAIL:
        return addr
    labels = domain.split(".")
    # example.co.uk keeps three labels; mail.example.com keeps two.
    keep = (
        3
        if len(labels) > 2
        and len(labels[-1]) == 2
        and labels[-2] in {"co", "com", "org", "net", "gov", "ac"}
        else 2
    )
    return ".".join(labels[-keep:])


def messages(query):
    out = subprocess.run(
        [
            "notmuch",
            "show",
            "--format=json",
            "--body=false",
            "--entire-thread=false",
            "--exclude=false",
            query,
        ],
        check=True,
        capture_output=True,
        text=True,
    ).stdout

    def walk(node):
        if isinstance(node, dict):
            if node.get("match"):
                yield node
        elif isinstance(node, list):
            for child in node:
                yield from walk(child)

    for msg in walk(json.loads(out)):
        if all(Path(f).parent.parent.name in SKIP_FOLDERS for f in msg["filename"]):
            continue
        sender = next(
            (a.lower() for _, a in getaddresses([msg["headers"].get("From", "")])), ""
        )
        if sender and not is_self(sender):
            yield sender, msg


def is_confirmation(msg):
    return bool(CONFIRMATION.search(msg["headers"].get("Subject", "")))


def confirmations():
    """Latest confirmed email change per sender, from any mailbox, any date."""
    latest = {}
    for sender, msg in messages(CONFIRMATION_QUERY):
        if is_confirmation(msg):
            key = sender_key(sender)
            latest[key] = max(latest.get(key, 0), msg["timestamp"])
    return latest


def recipient(msg):
    headers = msg["headers"]
    old = {
        a.lower()
        for _, a in getaddresses([headers.get("To", ""), headers.get("Cc", "")])
        if is_old(a.lower())
    }
    if old:
        return old
    # Bcc and list mail name some other address; the maildir it landed in says
    # which retired account it reached.
    return {f"({d})" for f in msg["filename"] for d in MAILDIRS if f"/mail/{d}/" in f}


def collect(days, confirmed):
    scope = " or ".join(
        [f"path:{d}/**" for d in MAILDIRS] + ["to:ondy.me", "to:kyleondy@gmail.com"]
    )
    groups = {}
    for sender, msg in messages(f"date:{days}days.. and ({scope})"):
        # The notice a service sends the old address about the change is not
        # a sign it still uses that address.
        if sender_key(sender) in confirmed and is_confirmation(msg):
            continue
        g = groups.setdefault(
            sender_key(sender), {"count": 0, "last": 0, "to": set(), "subject": ""}
        )
        g["count"] += 1
        g["to"] |= recipient(msg)
        if msg["timestamp"] > g["last"]:
            g["last"] = msg["timestamp"]
            g["subject"] = msg["headers"].get("Subject", "")
    return groups


def day(ts):
    return datetime.fromtimestamp(ts).strftime("%Y-%m-%d")


def table(rows, out, confirmed):
    for key, g in rows:
        print(
            f"{key:<36} {g['count']:>4}  {day(g['last'])}  {', '.join(sorted(g['to']))}",
            file=out,
        )
        print(f"    latest subject: {g['subject'][:100]}", file=out)
        if key in confirmed:
            print(
                f"    email change confirmed {day(confirmed[key])}, retired address still mailed after it",
                file=out,
            )


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--days", type=int, default=30, help="look back this many days (default 30)"
    )
    args = parser.parse_args()

    confirmed = confirmations()
    rows = sorted(
        collect(args.days, confirmed).items(),
        key=lambda kv: kv[1]["last"],
        reverse=True,
    )
    people = [r for r in rows if "@" in r[0]]
    others = [r for r in rows if "@" not in r[0]]
    done = [r for r in others if r[1]["last"] <= confirmed.get(r[0], 0)]
    services = [r for r in others if r[1]["last"] > confirmed.get(r[0], 0)]

    if people:
        print(
            f"People who mailed a retired address in the last {args.days} days (not sent to pi):",
            file=sys.stderr,
        )
        table(people, sys.stderr, confirmed)
        print(file=sys.stderr)

    if done:
        print(
            "Email change confirmed, nothing to the retired address since (not sent to pi):",
            file=sys.stderr,
        )
        for key, g in done:
            print(f"  {key:<34} confirmed {day(confirmed[key])}", file=sys.stderr)
        print(file=sys.stderr)

    # Empty stdout tells mail-stragglers.sh there is nothing to hand to pi.
    if services:
        print(
            f"Senders that mailed ondy.me or kyleondy@gmail.com in the last {args.days} days."
        )
        print(
            "Columns: sending domain, messages, last seen, retired address it reached.\n"
        )
        table(services, sys.stdout, confirmed)
        # Exact-domain matching misses a company that confirms from one
        # domain and markets from another, so pi gets the list to merge.
        print("\nEmail changes already confirmed, any mailbox (sending domain, date):")
        for key, ts in sorted(confirmed.items(), key=lambda kv: kv[1], reverse=True):
            if "@" not in key:
                print(f"{key:<36} {day(ts)}")


if __name__ == "__main__":
    main()
