"""Draw pika's backup status on its console, redrawn every minute.

pika's own rows come from the exporters on loopback, so they keep working
when tiger, the network or the monitoring stack is what broke. The TIGER
rows query tiger's VictoriaMetrics and say so when it does not answer.
"""

import base64
import fcntl
import json
import os
import re
import socket
import sys
import termios
import time
import urllib.parse
import urllib.request

EXPORTERS = (
    "http://127.0.0.1:9100/metrics",
    "http://127.0.0.1:9134/metrics",
    "http://127.0.0.1:8429/metrics",  # vmagent
)
REFRESH = 60  # seconds

# vmagent's remote write login, read from the systemd credential of the
# same name. The query API sits behind the same Caddy basic auth.
TIGER_QUERY = "https://metrics.tiger.infra.ondy.org/api/v1/query"
TIGER_USER = "monitoring"
TIGER_SERIES = '{host="tiger",__name__=~"zfs_pool_.*|zfs_vdev_errors|zfs_dataset_used_bytes|smartctl_.*"}'
# Listed rather than discovered, so a pool that fails to import reads
# "no data" instead of dropping off the screen.
TIGER_POOLS = ("storage", "scratch")
# scratch holds one dataset the size of the pool.
TIGER_SHARES = "storage"

# Local hours the panel is lit, [9, 20). Outside them the console is
# blanked, which drops the HDMI signal and the monitor sleeps.
SCREEN_HOURS = range(9, 20)
TIOCL_UNBLANKSCREEN, TIOCL_BLANKSCREEN = 4, 14

HOUR = 3600
DAY = 86400

# The vmalert rules' thresholds (monitoring-stack/vmalert.nix), so the
# screen turns colour at the same point the alert mail goes out.
REPLICA_WARN, REPLICA_CRIT = 36 * HOUR, 72 * HOUR
PUSH_WARN, PUSH_CRIT = 36 * HOUR, 96 * HOUR
SCRUB_WARN = 45 * DAY
RECONCILE_WARN = 14 * DAY
CAPACITY_WARN = 0.85
# Not a vmalert rule, since tiger cannot alert on what it never receives.
# HostAbsent there fires 10 minutes after pika goes quiet, so by red the
# alert mail should already be in the inbox.
METRICS_WARN, METRICS_CRIT = 5 * 60, 15 * 60
# Reallocated, reported uncorrectable, pending, offline uncorrectable.
FAILING_ATTRIBUTES = {"5", "187", "197", "198"}

POOL = "tank"
DATASETS = ("backups", "photos", "projects")
# projects is replicated but never pushed (pika/configuration.nix).
PREFIXES = ("photos", "backups")
POOL_STATES = (
    "ONLINE",
    "DEGRADED",
    "FAULTED",
    "OFFLINE",
    "UNAVAIL",
    "REMOVED",
    "SUSPENDED",
)

OK, WARN, CRIT, PLAIN = "\033[32m", "\033[33m", "\033[1;31m", ""
RESET = "\033[0m"
ANSI = re.compile(r"\033\[[0-9;?]*[A-Za-z]")
SAMPLE = re.compile(r"^([a-zA-Z_:][a-zA-Z0-9_:]*)(?:\{(.*)\})?\s+(\S+)")
LABEL = re.compile(r'(\w+)="((?:[^"\\]|\\.)*)"')


def scrape():
    samples, errors = [], []
    for url in EXPORTERS:
        try:
            with urllib.request.urlopen(url, timeout=10) as response:
                text = response.read().decode()
        except OSError as e:
            errors.append(f"{url}: {e}")
            continue
        for line in text.splitlines():
            m = SAMPLE.match(line)
            if m:
                samples.append((m[1], dict(LABEL.findall(m[2] or "")), float(m[3])))
    return samples, errors


def query_tiger():
    """Return tiger's samples and None, or None and why not."""
    credentials = os.environ.get("CREDENTIALS_DIRECTORY", "")
    try:
        with open(os.path.join(credentials, "monitoring_password")) as f:
            password = f.read().strip()
        token = base64.b64encode(f"{TIGER_USER}:{password}".encode()).decode()
        request = urllib.request.Request(
            TIGER_QUERY + "?" + urllib.parse.urlencode({"query": TIGER_SERIES}),
            headers={"Authorization": f"Basic {token}"},
        )
        with urllib.request.urlopen(request, timeout=10) as response:
            result = json.load(response)["data"]["result"]
        return [
            (r["metric"]["__name__"], r["metric"], float(r["value"][1])) for r in result
        ], None
    except (OSError, ValueError, KeyError) as e:
        return None, str(e)


def series(samples, metric, **labels):
    return [
        (lab, v)
        for n, lab, v in samples
        if n == metric and all(lab.get(k) == want for k, want in labels.items())
    ]


def value(samples, metric, **labels):
    found = series(samples, metric, **labels)
    return found[0][1] if found else None


def ago(seconds):
    if seconds < 60:
        return "just now"
    if seconds < 2 * HOUR:
        return f"{seconds // 60:.0f}m ago"
    if seconds < 2 * DAY:
        return f"{seconds // HOUR:.0f}h ago"
    return f"{seconds // DAY:.0f}d ago"


def size(n):
    """Bytes the way zfs list prints them: binary units, 3 significant digits."""
    for unit, scale in (("T", 2**40), ("G", 2**30), ("M", 2**20)):
        if n >= scale:
            break
    v = n / scale
    return (
        f"{v:.2f}{unit}"
        if v < 10
        else f"{v:.1f}{unit}"
        if v < 100
        else f"{v:.0f}{unit}"
    )


def render(samples, errors, tiger, tiger_error, now, sent_at):
    def running(unit):
        return value(samples, "node_systemd_unit_state", name=unit, state="active") == 1

    problems = []

    def cell(text, level=PLAIN, width=0):
        if level in (WARN, CRIT):
            problems.append(level)
        return f"{level}{text:<{width}}{RESET}"

    def age(ts, warn, crit=None, width=10):
        if ts is None:
            return cell("no data", WARN, width)
        seconds = now - ts
        # A snapshot dated ahead would read as fresh until the clock caught up.
        if seconds < -HOUR:
            return cell("future", CRIT, width)
        seconds = max(seconds, 0)
        if crit is not None and seconds > crit:
            return cell(ago(seconds), CRIT, width)
        return cell(ago(seconds), WARN if seconds > warn else OK, width)

    def pool_lines(m, pool):
        health = value(m, "zfs_pool_health", pool=pool)
        if health is None:
            state = cell("no data", WARN, 10)
        elif int(health) < len(POOL_STATES):
            state = cell(POOL_STATES[int(health)], OK if health == 0 else CRIT, 10)
        else:
            state = cell(f"state {health:.0f}", CRIT, 10)
        alloc = value(m, "zfs_pool_allocated_bytes", pool=pool)
        total = value(m, "zfs_pool_size_bytes", pool=pool)
        if alloc is None or not total:
            used = cell("no data", WARN)
        else:
            used = cell(
                f"{size(alloc)} of {size(total)}  {alloc / total:.0%}",
                WARN if alloc / total > CAPACITY_WARN else PLAIN,
            )

        scrub_end = value(m, "zfs_pool_scrub_end_timestamp_seconds", pool=pool)
        if value(m, "zfs_pool_scrub_in_progress", pool=pool) == 1:
            scrub = cell("running", OK, 10)
        elif scrub_end == 0:
            scrub = cell("never", WARN, 10)
        else:
            scrub = age(scrub_end, SCRUB_WARN)
        vdev_errors = sum(v for _, v in series(m, "zfs_vdev_errors", pool=pool))
        return [
            f"POOL {pool:<16}{state}  {used}",
            f"  {'scrub':<19}{scrub}  "
            + cell(f"{vdev_errors:.0f} vdev errors", CRIT if vdev_errors else PLAIN),
        ]

    def drives_line(m):
        drives = []
        for labels, healthy in series(m, "smartctl_device_smart_healthy"):
            device = labels.get("device", "?")
            failing = (
                healthy == 0
                or value(m, "smartctl_selftest_log_has_errors", device=device) == 1
                or any(
                    v > 0
                    for lab, v in series(m, "smartctl_ata_attribute_raw", device=device)
                    if lab.get("attribute_id") in FAILING_ATTRIBUTES
                )
            )
            worn = value(m, "smartctl_nvme_percentage_used", device=device)
            text = device if worn is None else f"{device} {worn:.0f}% worn"
            if failing:
                drives.append(cell(f"{device} FAIL", CRIT))
            else:
                drives.append(
                    cell(text, WARN if worn is not None and worn >= 100 else OK)
                )
        return f"  {'drives':<19}" + ("   ".join(drives) or cell("no data", WARN))

    body = pool_lines(samples, POOL) + [drives_line(samples)]

    body += ["", f"{'PULL FROM TIGER':<21}{'newest':<12}snapshots"]
    for name in DATASETS:
        dataset = f"{POOL}/{name}"
        newest = age(
            value(
                samples,
                "zfs_dataset_latest_snapshot_timestamp_seconds",
                dataset=dataset,
            ),
            REPLICA_WARN,
            REPLICA_CRIT,
        )
        count = value(samples, "zfs_dataset_snapshot_count", dataset=dataset)
        if count is None:
            snapshots = cell("no data", WARN, 9)
        else:
            snapshots = cell(f"{count:.0f}", CRIT if count == 0 else PLAIN, 9)
        note = (
            "  " + cell("pulling", OK)
            if running(f"syncoid-storage-{name}.service")
            else ""
        )
        body.append(f"  {name:<19}{newest}  {snapshots}{note}")

    body += ["", f"{'OFFSITE S3':<21}{'pushed':<12}{'missing':<10}checked"]
    for prefix in PREFIXES:
        pushing = running(f"s3-archive-push-{prefix}.service")
        last = value(
            samples, "s3_archive_push_last_success_timestamp_seconds", prefix=prefix
        )
        # A push in flight writes nothing until it returns, so a long one is
        # not stale until the critical line (the S3ArchivePushStale guard).
        if pushing and last is not None and now - last <= PUSH_CRIT:
            pushed = cell(ago(max(now - last, 0)), OK, 10)
        else:
            pushed = age(last, PUSH_WARN, PUSH_CRIT)
        missing = value(samples, "s3_reconcile_missing_objects", prefix=prefix)
        if missing is None:
            gone = cell("no data", WARN, 10)
        else:
            gone = cell(f"{missing:.0f}", CRIT if missing else PLAIN, 10)
        checked = age(
            value(samples, "s3_reconcile_last_run_timestamp_seconds", prefix=prefix),
            RECONCILE_WARN,
        )
        notes = []
        if pushing:
            notes.append(cell("pushing", OK))
        if value(samples, "s3_reconcile_prune_blocked", prefix=prefix):
            notes.append(cell("prune blocked", WARN))
        body.append(f"  {prefix:<19}{pushed}  {gone}{checked}  " + "  ".join(notes))

    body += [
        "",
        f"{'METRICS TO TIGER':<21}" + age(sent_at, METRICS_WARN, METRICS_CRIT),
    ]

    failed = [
        lab.get("name", "?")
        for lab, v in series(samples, "node_systemd_unit_state", state="failed")
        if v == 1
    ]
    boot = value(samples, "node_boot_time_seconds")
    load = value(samples, "node_load1")
    system = [
        "up " + ("?" if boot is None else ago(now - boot).removesuffix(" ago")),
        "load " + ("?" if load is None else f"{load:.2f}"),
        "failed units " + (cell(", ".join(failed[:3]), CRIT) if failed else "none"),
    ]
    body += ["", "   ".join(system), ""]

    # Yellow, not red: METRICS TO TIGER goes red once an outage outlasts a
    # deploy's restart.
    if tiger is None:
        body.append(f"{'TIGER':<21}" + cell(f"unreachable: {tiger_error}", WARN))
    else:
        body.append("TIGER")
        for pool in TIGER_POOLS:
            body += pool_lines(tiger, pool)
        body.append(drives_line(tiger))
        shares = sorted(
            (
                (lab["name"].split("/")[1], v)
                for lab, v in series(tiger, "zfs_dataset_used_bytes", pool=TIGER_SHARES)
                if lab.get("name", "").count("/") == 1
            ),
            key=lambda share: -share[1],
        )
        cells = [f"{name:<12}{size(v):>6}" for name, v in shares] or [
            cell("no data", WARN)
        ]
        for i in range(0, len(cells), 3):
            label = "shares" if i == 0 else ""
            body.append(f"  {label:<19}" + "   ".join(cells[i : i + 3]))

    body += [cell(e, CRIT) for e in errors]

    if not problems:
        verdict = cell("ALL OK", OK)
    else:
        n = len(problems)
        verdict = cell(
            f"{n} PROBLEM{'S' if n > 1 else ''}", CRIT if CRIT in problems else WARN
        )
    clock = time.strftime("%a %Y-%m-%d %H:%M", time.localtime(now))
    header = f"{socket.gethostname().upper():<21}{verdict}"
    return [header, clock, ""] + body


def sent_requests(samples):
    found = [
        v
        for n, lab, v in samples
        if n == "vmagent_remotewrite_requests_total" and lab.get("status_code") == "2XX"
    ]
    return sum(found) if found else None


def screen(now):
    lit = time.localtime(now).tm_hour in SCREEN_HOURS
    # TIOCLINUX wants CAP_SYS_ADMIN unless the tty is the caller's
    # controlling terminal, which StandardInput=tty makes it. Set every
    # refresh, so a restart overnight goes dark again within a minute. A
    # forced blank ignores the keyboard until the next unblank.
    code = TIOCL_UNBLANKSCREEN if lit else TIOCL_BLANKSCREEN
    try:
        fcntl.ioctl(sys.stdin.fileno(), termios.TIOCLINUX, bytes([code]))
    except OSError as e:
        return [f"screen {'unblank' if lit else 'blank'}: {e}"]
    return []


def main():
    out = sys.stdout
    out.write("\033[?25l")  # hide the cursor
    # The counter says how many sends, not when, so the age runs from this
    # process's start until it first sees one.
    sent_at, sent = time.time(), None
    while True:
        now = time.time()
        samples, errors = scrape()
        tiger, tiger_error = query_tiger()
        count = sent_requests(samples)
        # A lower count is a vmagent restart resetting it, not a send.
        if count is not None and sent is not None and count > sent:
            sent_at = now
        sent = count
        errors += screen(now)
        frame = render(samples, errors, tiger, tiger_error, now, sent_at)
        try:
            cols, rows = os.get_terminal_size(out.fileno())
        except OSError:
            cols, rows = 0, 0
        width = max(len(ANSI.sub("", line)) for line in frame)
        left = " " * max((cols - width) // 2, 0)
        top = max((rows - len(frame)) // 2, 0)
        # Home and overwrite rather than clear, so a redraw never flickers and
        # a kernel message that landed on the console is gone by the next one.
        out.write(
            "\033[H"
            + "\033[K\n" * top
            + "".join(f"{left}{line}\033[K\n" for line in frame)
            + "\033[J"
        )
        out.flush()
        time.sleep(REFRESH - time.time() % REFRESH)


if __name__ == "__main__":
    main()
