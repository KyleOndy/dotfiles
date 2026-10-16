"""Move messages from INBOX to Archive on kyle@ondy.org's IMAP server.

Reads Message-IDs on stdin, one per line, as `notmuch search --output=messages`
prints them. Without --move it only lists what matched.
"""

import imaplib
import subprocess
import sys

ACCOUNT = "kyle@ondy.org"
HOST = "london.mxroute.com"

move = sys.argv[1:] == ["--move"]
ids = [
    line.strip().removeprefix("id:").strip('"') for line in sys.stdin if line.strip()
]
if not ids:
    sys.exit("no Message-IDs on stdin")

password = subprocess.run(
    ["/run/secrets/rendered/mbsync-password-script", ACCOUNT],
    capture_output=True,
    text=True,
    check=True,
).stdout.strip()
imap = imaplib.IMAP4_SSL(HOST)
imap.login(ACCOUNT, password)
del password
imap.select("INBOX", readonly=not move)

uids = []
for mid in ids:
    _, data = imap.uid("SEARCH", None, "HEADER", "Message-ID", f'"<{mid}>"')
    found = data[0].split()
    if len(found) != 1:
        print(f"skip {mid}: {len(found)} matches in INBOX")
        continue
    _, msg = imap.uid("FETCH", found[0], "(BODY.PEEK[HEADER.FIELDS (SUBJECT)])")
    print(found[0].decode(), " ".join(msg[0][1].decode(errors="replace").split()))
    uids += found

if move and uids:
    if "MOVE" not in imap.capabilities:
        sys.exit(f"server lacks MOVE: {imap.capabilities}")
    status, resp = imap.uid("MOVE", b",".join(uids).decode(), "Archive")
    print(f"moved {len(uids)}: {status} {resp}")
elif uids:
    print(f"{len(uids)} would move; rerun with --move")

imap.logout()
