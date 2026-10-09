#!/usr/bin/env python3
"""Report on ondy.org junk filtering from the local maildir.

Prints senders and subjects, so the output is private: read it, never
commit it.
"""

import argparse
import collections
import datetime
import email.utils
import fnmatch
import os
import re
from email import policy
from email.parser import BytesHeaderParser

FOLDERS = ["Inbox", "Junk", "Archive", "Deleted Messages", "Sent"]
KEPT = ("Inbox", "Archive")
# A Junk sender is "likely legitimate" when this many of its domain's
# unflagged messages were kept.
KEPT_DOMAIN_MIN = 3


def parse_rules(path):
    """Return (label, action, test) for each top-level if-block.

    Handles only the forms mail/ondy.org.sieve uses: address :is or
    :domain :is/:matches on "from", and header :contains/:matches.
    """
    text = open(path).read()
    if text.startswith("\0GITCRYPT"):
        raise SystemExit(f"{path} is still encrypted: run git-crypt unlock")
    rules = []
    for cond, body in re.findall(r"^if (.*?)\{(.*?)^\}", text, re.M | re.S):
        values = [v.lower() for v in re.findall(r'"([^"]*)"', cond)]
        action = "junk" if "fileinto" in body else "keep"
        if cond.startswith("address :domain"):
            field, pats = "dom", values[1:]
        elif cond.startswith("address :is"):
            field, pats = "addr", values[1:]
        elif cond.startswith("header"):
            field, pats = values[0], values[1:]
        else:
            continue
        glob = ":matches" in cond
        contains = ":contains" in cond
        for p in pats:
            rules.append((p, action, field, glob, contains))
    return rules


def rule_matches(rule, msg):
    pat, _, field, glob, contains = rule
    value = msg.get(field, "")
    if contains:
        return pat in value
    if glob:
        return fnmatch.fnmatchcase(value, pat)
    return value == pat


def load(maildir):
    parser = BytesHeaderParser(policy=policy.default)
    msgs = []
    for folder in FOLDERS:
        for sub in ("cur", "new"):
            d = os.path.join(maildir, folder, sub)
            if not os.path.isdir(d):
                continue
            for name in os.listdir(d):
                with open(os.path.join(d, name), "rb") as fh:
                    try:
                        h = parser.parse(fh)
                    except Exception:
                        continue
                msgs.append(summarize(folder, h))
    return msgs


def header(h, name):
    try:
        return re.sub(r"\s+", " ", str(h.get(name, "")))
    except Exception:
        return ""


def summarize(folder, h):
    addr = email.utils.parseaddr(header(h, "From"))[1].lower()
    status = header(h, "X-Spam-Status")
    m = re.match(r"(Yes|No), score=(-?[\d.]+)", status)
    try:
        date = email.utils.parsedate_to_datetime(header(h, "Date")).date()
    except Exception:
        date = None
    report = header(h, "X-Spam-Report")
    return {
        "folder": folder,
        "date": date,
        "addr": addr,
        "dom": addr.rpartition("@")[2],
        "subject": header(h, "Subject").lower(),
        "x-spam-status": status.lower(),
        "flagged": bool(m) and m.group(1) == "Yes",
        "score": float(m.group(2)) if m else None,
        "rules": [
            (r, float(p))
            for p, r in re.findall(r"(-?\d+\.\d+) ([A-Z][A-Z0-9_]+)", report)
            if float(p) > 0
        ],
        "unsub": h.get("List-Unsubscribe") is not None,
        "to": [
            a.lower()
            for _, a in email.utils.getaddresses([header(h, "To"), header(h, "Cc")])
        ],
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--maildir", default=os.path.expanduser("~/Mail/ondy.org"))
    ap.add_argument(
        "--sieve",
        default=os.path.join(
            os.path.dirname(os.path.abspath(__file__)), "ondy.org.sieve"
        ),
    )
    ap.add_argument(
        "--since",
        type=datetime.date.fromisoformat,
        default=datetime.date.today() - datetime.timedelta(days=30),
        help="first day of the review window (default: 30 days ago)",
    )
    args = ap.parse_args()

    rules = parse_rules(args.sieve)
    msgs = load(args.maildir)
    recent = [m for m in msgs if m["date"] and m["date"] >= args.since]
    year_ago = datetime.date.today() - datetime.timedelta(days=365)
    sent_to = {a for m in msgs if m["folder"] == "Sent" for a in m["to"]}
    kept_dom = collections.Counter(
        m["dom"] for m in msgs if m["folder"] in KEPT and not m["flagged"]
    )

    junk = [m for m in recent if m["folder"] == "Junk"]
    print(f"# Review since {args.since}: {len(recent)} messages, {len(junk)} in Junk\n")

    print("## Junk from senders you otherwise keep")
    print("domain | count | scores | top rules | latest subject")
    legit = collections.defaultdict(list)
    for m in junk:
        if kept_dom[m["dom"]] >= KEPT_DOMAIN_MIN or m["addr"] in sent_to:
            legit[m["dom"]].append(m)
    for dom, ms in sorted(legit.items(), key=lambda kv: -len(kv[1])):
        top = collections.Counter(r for m in ms for r, _ in m["rules"]).most_common(3)
        scores = sorted(m["score"] for m in ms if m["score"] is not None)
        latest = max(ms, key=lambda m: m["date"])
        addrs = sorted({m["addr"] for m in ms})
        print(
            f"{dom} ({', '.join(addrs)}) | {len(ms)} | {scores} | "
            f"{', '.join(r for r, _ in top)} | {latest['subject'][:60]}"
        )

    print("\n## Other Junk, top sender domains")
    other = collections.Counter(m["dom"] for m in junk if m["dom"] not in legit)
    print(", ".join(f"{d} {n}" for d, n in other.most_common(15)) or "none")

    print("\n## Rule hits (window / all time; rescues = flagged mail a keep rule kept)")
    print("rule | action | hits | rescues | last rescue")
    nonsent = [m for m in msgs if m["folder"] != "Sent"]
    for rule in rules:
        hits = [m for m in nonsent if rule_matches(rule, m)]
        win = [m for m in hits if m["date"] and m["date"] >= args.since]
        rescues = [m for m in hits if m["flagged"] and m["folder"] != "Junk"]
        last = max((m["date"] for m in rescues if m["date"]), default=None)
        note = ""
        if rule[1] == "keep" and (last is None or last < year_ago):
            note = "  <- no rescue in 12 months"
        if rule[1] == "keep":
            print(
                f"{rule[0]} | keep | {len(win)}/{len(hits)} | {len(rescues)} | {last}{note}"
            )
        else:
            print(f"{rule[0]} | {rule[1]} | {len(win)}/{len(hits)} | - | -")

    print("\n## Unsubscribe candidates: unflagged list mail received in the window")
    unsub = collections.Counter(
        m["addr"]
        for m in recent
        if m["unsub"] and m["folder"] != "Sent" and not m["flagged"]
    )
    for addr, n in unsub.most_common(25):
        print(f"{n:4} {addr}")


if __name__ == "__main__":
    main()
