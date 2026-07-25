# Backup strategy

Three copies, two places, one offsite. tiger holds the live primary, a
Raspberry Pi pulls a second local copy, and S3 Glacier Deep Archive holds
the offsite one.

This document is the design and the reasoning. Nothing in it is deployed
yet except the parts marked as already working.

State as measured 2026-07-25. The numbers go stale; the shape does not.

## Scope

In scope, and the only things in scope:

- `storage/photos`, 531G used, 333G referenced. The curated photo
  library plus `_provisional`.
- `storage/backups`, 650G used, 534G referenced. `kristen` (185G),
  `kyle` (75G), `videos` (34G), `apps` (25G).

That is ~1.18 TB of full ZFS send once tiger's snapshot history comes
along, and ~700 GB of current files for the S3 tier.

Out of scope, deliberately:

- **`storage/media`** (4.34T). Re-acquirable. Not worth the drives.
- **`storage/immich`** (334G). The 233G of uploaded originals are being
  deleted out of band. Immich becomes a read-only view of the curated
  archive through `externalLibraryPaths`, which `immich.nix:119-121`
  already enforces with `ReadOnlyPaths`. Once that lands, immich holds no
  originals and needs no backup.
- **tiger's root disk.** jellyfin, navidrome, sabnzbd, prowlarr, the
  \*arrs, and the monitoring stack are all rebuildable from the flake.
- **`storage/scratch-big`, `scratch/scratch`, `storage/data`.** Scratch is
  scratch, and `storage/data` is empty.
- **Ingest.** Google Photos handles phone capture. Camera cards reach the
  library through `backup-photos` and `photos-promote`, run by hand.

### The one rule that makes this work

The backup boundary is the dataset. Nothing gets backed up because it is
important. It gets backed up because it lives in `storage/photos` or
`storage/backups`.

Anything new that matters has to be made to land in one of those two
datasets. That is a deliberate constraint, not a limitation. It means the
question "is this backed up?" has a one-word answer you can check with
`zfs list`, instead of an audit.

## Where we actually are

The gap between the intent and the reality, measured rather than assumed.

| Data                           | Size  | Snapshotted | Offsite           |
| ------------------------------ | ----- | ----------- | ----------------- |
| `storage/photos` archive       | 7.7G  | yes         | yes, 935 objects  |
| `storage/photos` \_provisional | 321G  | yes         | partial, drifted  |
| `storage/photos` \_projects    | 2.2G  | yes         | yes, Standard-IA  |
| `/mnt/backups/kristen`         | 185G  | yes         | **no**            |
| `/mnt/backups/kyle`            | 75G   | yes         | **no**            |
| `/mnt/backups/videos`          | 34G   | yes         | **no**            |
| `/mnt/backups/apps`            | 25G   | yes         | **no**            |
| `storage/immich`               | 334G  | **no**      | no (out of scope) |
| `storage/media`                | 4.34T | **no**      | no (out of scope) |

So 319G of irreplaceable data has exactly one copy, and it sits on the
least trustworthy hardware in the house. More on that in the risks.

### The `_provisional` drift

`_provisional` is in S3, and it has quietly fallen behind:

```
local, non-RAF:   50,863 files    298.3 GiB
in S3:            50,797 objects  219.0 GiB
gap:                  66 objects   ~79 GiB
```

The extension histogram says `_provisional` holds exactly 66 `.mov`
files. The missing objects are the videos, roughly 1.2 GiB each.

This is not a bug in `photos-fanout`. Read the header comment in
`nix/pkgs/photos-fanout/photos-fanout.sh:5-17`: fanout handles `archive/`
and `_projects/` from tiger, and the laptop's `backup-photos --s3` owns
`_provisional/`. The division is intentional. The problem is that
`backup-photos` is a manual script, and it last ran around Aug 2025.

The fix is to stop depending on a human. `_provisional` moves onto the
automated tiger-side schedule.

### The silent skip

Every run of `photos-fanout` ends like this:

```
External HDD not mounted at /mnt/photos-external, skipping that copy.
Fan-out complete!
```

Exit code 0. `photos-fanout.sh:53-55` treats the external HDD as best
effort, and best effort with no alerting is indistinguishable from not
trying. This has been the state for at least months.

The Pi supersedes that leg entirely, so we delete it rather than fix it.

### No backup alerting at all

`monitoring-stack/vmalert.nix` carries 48 rules. None mentions backup,
snapshot, sanoid, scrub, or zpool health. ZFS appears twice, only as
`node_zfs_arc_size` being subtracted out of memory-pressure math.

`SystemdServiceFailed` looks like coverage and is not. A `oneshot` that
never runs never enters `failed`. A disabled timer, a misfire, a host
that was down at the trigger: all invisible.

Every backup alert has to be absence-based. Alert on the lack of a fresh
success, not on the presence of an error.

### The offsite copy is deletable

`tf/photos-backup.tf:215-217` grants the `svc.photos-backup` credential
`s3:PutObject`, `s3:DeleteObject`, and `s3:DeleteObjectVersion`. That
credential lives on tiger at
`/run/secrets/photos_backup_aws_credentials`.

A compromised tiger can therefore permanently destroy the offsite copy,
versions included. Bucket versioning does not save you from a principal
that can delete versions.

Every sync leg also runs `--delete` (`photos-fanout.sh:32`, `:37`,
`:52`). A local `rm` propagates to S3 within a day.

### The 216G that looks like a backup

`/mnt/backups/photos-backup` is 216G, and it is a stale copy of the photo
tree: same `helios.db`, same `infra/`, same `archive/` and
`_provisional/`, last touched Aug 2025.

It is on the same pool as the original. It buys no redundancy. It eats
216G of a pool at 80% capacity.

## Target architecture

```
tiger (DMZ)                  pi (LAN)                    AWS
-----------                  --------                    ---
storage/photos    --send-->  tank/photos     --sync-->   Deep Archive
storage/backups   --send-->  tank/backups    --sync-->   Deep Archive

raidz1, 3x 4TB SMR           mirror, 2x USB3 HDD         versioned
sanoid                       sanoid, longer retention    put-only IAM
80% full                     on UPS                      no --delete
```

Read the arrows as trust, not just data. Every arrow is initiated by the
host on its right.

tiger holds no credential for the Pi and no credential for AWS. The Pi
pulls from tiger and pushes to S3. If tiger is compromised, the blast
radius is tiger.

## Tier 1: tiger

Nothing structural changes here in the near term, and that is the point.
You do not rebuild the only copy. tiger gets touched after the Pi holds a
verified second copy, not before.

What changes now: nothing on the pool. What changes later: see the risk
register on the SMR drives.

Sanoid stays as configured (`tiger/configuration.nix:88`), covering
`storage/backups` (hourly 4, daily 31, monthly 24, yearly 10) and
`storage/photos` (daily 8, monthly 12). `autoScrub` is on at
`:85`, `autoSnapshot` off at `:86`.

The unsnapshotted datasets are a decision, recorded here so it reads as
one: `storage/media` and `storage/scratch-big` are replaceable,
`storage/data` is empty, `scratch/scratch` is scratch, and
`storage/immich` is on its way out.

The pools were created by hand and are not declared in Nix. The `zfs
create` invocation is recorded at `tiger/configuration.nix:200`, and the
`acltype=posixacl` that `storage/photos` needs is at `:284-286`. The
`disko` input was removed in `e94efb4e`, so this stays manual. Any new
dataset needs the same treatment.

### Delegating send to the Pi

Pull needs no write permission on tiger at all:

```bash
zfs allow -u svc.syncoid send,hold,release storage/photos
zfs allow -u svc.syncoid send,hold,release storage/backups
```

The `svc.backup` and `svc.syncoid` accounts already exist as locked
placeholders at `tiger/configuration.nix:141-165`. The comment at `:157`
proposes `receive,create,mount,destroy,snapshot,hold`, which is push
semantics from when the plan pointed the other way. Pull is
`send,hold,release` and nothing more.

Snapshot creation stays with sanoid on tiger, so syncoid runs with
`--no-sync-snap` and never needs the `snapshot` verb.

## Tier 2: the Pi

Hardware we already own. A Pi 4 with 4GB RAM, two matched USB3 external
HDDs somewhere between 2 and 4TB, ZFS mirror, all of it on a UPS.

The UPS matters more than it sounds. Brownout during a write is the
cleanest way to fault a pool, and two spinning drives at simultaneous
spin-up will pull more than a Pi 4's 1.2A USB budget if they are
bus-powered.

### Isolation comes from the router

tiger sits in the DMZ. The Pi sits on the LAN. The DMZ cannot initiate
connections to the LAN.

That is a stronger guarantee than an SSH forced-command, because it is
enforced by a device that is not the one we are defending against. The Pi
opens every connection: syncoid pulls from tiger, vmagent and promtail
push metrics and logs to tiger, and the S3 sync goes straight out.

### Two flags that would undo all of it

**Never `zfs recv -F`. Never `syncoid --force-delete`.**

Both make the receiving side roll back or destroy datasets to match the
source. A compromised tiger cannot reach the Pi, but it can absolutely
answer a request the Pi made. Those two flags turn that answer into a
wipe of the second copy.

This is the single most important line in this document.

### Host configuration

- **Register with `mkNixosSystem`, `system = "aarch64-linux"`.** Do not
  copy cogsworth's `inputs.nixos-raspberrypi.lib.nixosSystem` block. ZFS
  is an out-of-tree module and lags vendor RPi kernels. A Pi 4 runs fine
  on the stock nixpkgs aarch64 kernel, and cogsworth force-disables ZFS
  anyway (`cogsworth/configuration.nix:150`).
- **Build on trex, not tiger.** `tiger/configuration.nix:61` sets
  `binfmt.emulatedSystems`, and `deployment_target.nix:102` sets
  `trusted-substituters = [ "ssh://svc.deploy@tiger.dmz.1ella.com" ]`.
  Left alone, tiger builds the closure the Pi runs, which is a
  supply-chain path around the firewall we just built. trex already has
  `nixosVmBasedLinuxBuilder.enable = true`.
- **`networking.hostId` is required for ZFS.** tiger has one at `:71`,
  cogsworth has none. Easy to miss.
- **Cap the ARC.** On 4GB, the 50% default is too much:
  ```nix
  boot.extraModprobeConfig = "options zfs zfs_arc_max=1610612736";
  ```
- **`compression=lz4`, not zstd.** The Cortex-A72 bottlenecks on zstd,
  and backup throughput is already slow enough.
- **`dedup=off`, `atime=off`, `xattr=sa`, `acltype=posixacl`.** The last
  one matches what `storage/photos` got by hand on tiger.
- **Received datasets get `readonly=on`.**
- **Monthly `services.zfs.autoScrub`.** Scrubs are how you find out the
  USB bridge lied to you.
- **Its own sanoid, with retention at least as long as tiger's.** The
  invariant: Pi retention >= tiger retention, always. Proposed daily 30 /
  monthly 24 / yearly 10 against tiger's `storage/photos` daily 8 /
  monthly 12. If the Pi ever holds less history than tiger, tiger pruning
  an old snapshot cascades into the backup.
- **Monitoring in agent mode:** vmagent, promtail, node_exporter, plus
  `zfsExporter`. Copy cogsworth's block. All of it pushes outward, which
  is why it works across the DMZ boundary, and which is what makes
  absence-based alerting possible when the Pi is the thing that died.
- **`sdCardOptimization`:** enable if root stays on the SD card, skip if
  root moves to USB.
- **sops:** derive a new age key from the Pi's SSH host key and enroll
  it. The recipe is in `.sops.yaml`'s own comments:
  ```bash
  nix-shell -p ssh-to-age --run "ssh-keyscan $host | ssh-to-age"
  sops -r updatekeys ./nix/secrets/secrets.yaml
  ```
- **deploy-rs node** alongside cogsworth's, with
  `(deployRsLib "aarch64-linux").activate.nixos`.

### Accepting that USB will misbehave

USB-SATA bridges reset under sustained load. Many ignore cache-flush and
FUA, which is exactly the ordering guarantee ZFS relies on. Most do not
pass SMART through, so the existing `smartctl_device_smart_healthy`
textfile collector at `deployment_target.nix:145-162` may see nothing on
these drives.

We are choosing ZFS anyway, because on an unreliable transport the
checksums are the point. A mirror that detects corruption and repairs it
from the good side is worth more here than it would be on good hardware.

A faulted pool is recovered with `zpool clear` and a resilver. On USB
HDD that is hours. Treat re-seeding as a routine event, not an incident.

### Mirror now, rotation later

Two drives in a mirror covers one failure mode: a drive dying. It does
not cover the Pi's PSU, a bridge corrupting both writes identically, a
mistyped `zfs destroy`, or a fire.

The better long-term answer is a third drive that gets synced, detached,
and stored somewhere else. That is a later phase. Mirror first, because
it is the fastest route to a real second copy and it needs no habit we
have not tested.

When the rotating drive arrives, it needs its own staleness alert.
"Offline copy older than N days" has to page, or the rotation quietly
stops happening and we will not find out.

## Tier 3: Glacier Deep Archive

Plain files, `aws s3 sync`, no restic.

That is a deliberate trade. restic would give us client-side encryption,
dedup, append-only snapshots, and real integrity verification. What it
takes away is the thing that matters most for family photos: anyone with
the bucket credentials and a browser can get them out. An encrypted repo
needs the tool plus a password that has to outlive me.

For irreplaceable photos, recoverable-by-a-non-technical-person wins.

### Fixes to the existing pipeline

**Drop `--delete` from every leg.** At $0.00099/GB-month, keeping deleted
objects around forever costs less than the risk of propagating an `rm`.
Pruning becomes a deliberate, rare, manual reconciliation.

**Strip delete from the IAM policy.** After dropping `--delete`, the
credential needs:

```
s3:PutObject
s3:GetObject
s3:ListBucket
s3:GetBucketLocation
```

and nothing else. Remove `s3:DeleteObject` and `s3:DeleteObjectVersion`
from `tf/photos-backup.tf:215-217`. A compromised host then cannot
destroy the offsite copy at all, current or noncurrent.

**Extend coverage.** `_provisional` moves onto the automated tiger-side
schedule, which closes the 66-object drift. `/mnt/backups/{kristen,kyle,
videos,apps}` gets added, which is the 319G that has no offsite copy
today. Each new prefix needs its own lifecycle rule; the header at
`tf/photos-backup.tf:20-24` already explains why a catch-all `filter {}`
is wrong here (it double-transitions the Standard-IA objects).

**Delete the external HDD leg.** `photos-fanout.sh:50-55` goes away. The
Pi does that job properly.

**Include the RAF files.** 752 files, 22.4 GiB in `_provisional`,
currently excluded by `photos-fanout.sh:32` on the reasoning at
`helios/README.md:65-67` that raws are a local edit cache. At Deep
Archive rates the exclusion saves about $0.02/month. Keep the raws.

**Move the sync to the Pi.** No AWS credential on tiger at all. See open
decisions.

### Cost

~700 GB of current files, of which 245.8 GB is already uploaded, so the
incremental push is ~450 GB.

|                     | Deep Archive                              |
| ------------------- | ----------------------------------------- |
| Store ~700 GB       | ~$0.69/month                              |
| Full restore        | ~$65 ($1.75 bulk retrieval + ~$63 egress) |
| Minimum retention   | 180 days                                  |
| Per-object overhead | 40 KB (8 KB of it at Standard rates)      |

Sources: [AWS S3 pricing](https://aws.amazon.com/s3/pricing/) for the
180-day minimum and the 40 KB metadata charge,
[Deep Archive rates](https://www.usage.ai/blogs/aws/storage-cost/glacier-deep-archive-pricing/)
for $0.00099/GB-month storage and $0.0025/GB bulk retrieval.

One oddity worth cleaning up: the only Standard-IA objects in the bucket
are four downloaded YouTube tutorials under
`_projects/2026-learning/tuturials/`. They are the most expensive per
byte in the bucket and the most replaceable data in it.

## Verification

Four layers. None of it is new machinery; every piece copies a pattern
already running in this repo.

### 1. Staleness alerts

Each backup leg writes a timestamp through the node_exporter textfile
collector. The directory is already created at
`deployment_target.nix:50`, and `smartctl-exporter` at `:145-162` is the
working example to copy.

```
backup_last_success_timestamp_seconds{job="syncoid-photos"} 1753459200
```

Alert on absence of freshness:

```
time() - backup_last_success_timestamp_seconds{job="syncoid-photos"} > 129600
```

`CalendarSyncStale` and `CalendarSyncCriticallyStale` at
`vmalert.nix:468` and `:509` are the same shape, already in production.

Proposed thresholds: daily legs warn at 36h and go critical at 72h. The
monthly reconciliation warns at 40 days.

### 2. zpool health and scrub age

Neither exists today, on either host. The `zfs_exporter` is already
running on tiger (`monitoring-stack/zfs_exporter.nix`, port 9134, all
pools).

Alert on any pool not `ONLINE`, and on last-scrub age over 45 days.

Note the metric rename recorded in `DASHBOARD_CONVENTIONS.md:413`:
`zfs_zpool_*` became `zfs_pool_*`, and the `poolname` label became
`pool`. Easy to write a rule that silently matches nothing.

`DASHBOARD_CONVENTIONS.md:133` also lists a `zfs-storage` dashboard. It
was never built. Build it.

### 3. Monthly manifest reconciliation

Compare local file count and byte total against the bucket, per prefix:

```bash
aws s3api list-objects-v2 --bucket "$BUCKET" --prefix "_provisional/" \
  --query '[length(Contents), sum(Contents[].Size)]'
```

LIST is metadata-only. No retrieval, no egress, no cost worth measuring.

Emit the deltas as metrics and alert on anything nonzero beyond a small
tolerance. This is exactly the check that would have caught 66 missing
`.mov` files instead of leaving them missing for a year.

### 4. Drills

**Quarterly:** pick a random directory, restore it from the Pi, checksum
it against tiger. Record that it happened.

**Annually:** `aws s3api restore-object` with the bulk tier on about five
random objects, then verify checksums. Costs pennies. The point is to
learn that the archive tier works before the day it has to.

Bulk retrieval is 48 hours. That is a bad thing to discover mid-disaster.

## Restore runbook

There is no S3 restore tooling in this repo today. No `restore-object`
wrapper, no test restore, nothing. `photos-recall` restores from tiger,
not from S3.

That has to change, because a backup you have never restored is a
hypothesis.

### A file or directory got deleted

Recover from a tiger snapshot. `storage/backups` keeps hourly 4, daily
31, monthly 24, yearly 10.

```bash
ls /mnt/photos/.zfs/snapshot/
cp -a /mnt/photos/.zfs/snapshot/autosnap_2026-07-24_00:00:03_daily/personal/photos/archive/<dir> \
      /mnt/photos/personal/photos/archive/
```

### A dataset got corrupted on tiger

Reverse the syncoid direction. Pull from the Pi back to tiger, into a new
dataset name, verify, then swap mountpoints. Do not receive over the live
dataset.

### tiger is gone

Rebuild tiger from the flake, create the pool by hand (see
`tiger/configuration.nix:200` and `:284-286` for the exact invocations),
then syncoid from the Pi to tiger. ~1.18 TB over GbE from USB HDD, so
plan on the better part of a day.

### tiger and the Pi are both gone

Deep Archive. Restore requests first, then wait, then download.

```bash
aws s3api list-objects-v2 --bucket "$BUCKET" --prefix "archive/" \
  --query 'Contents[].Key' --output text | tr '\t' '\n' > keys.txt

while read -r k; do
  aws s3api restore-object --bucket "$BUCKET" --key "$k" \
    --restore-request '{"Days":14,"GlacierJobParameters":{"Tier":"Bulk"}}'
done < keys.txt
```

48 hours for bulk. Then `aws s3 sync` normally; restored objects read
like any other. Budget ~$65 for the full ~700 GB.

Write this as a script before we need it, not during.

## Risks

**tiger's pool is the weakest link, not the strongest.** All three drives
in `storage` are `WDC_WD40EFAX`. The EFAX code at 2-6TB is WD Red
DM-SMR. A resilver is sustained-write, which is precisely the workload
where DM-SMR throughput collapses, and raidz1 carries zero redundancy for
the whole window. The pool is also at 80%, where ZFS allocation starts to
suffer.

That inverts the obvious reading of this architecture. The Pi is not a
nice-to-have second tier. It is insurance against a primary that is more
fragile than it looks. It is also why tiger does not get restructured
until the Pi copy exists and verifies. Long-term fix is CMR
replacements.

Sources:
[WD Red SMR model codes](https://david.gardiner.net.au/2021/07/ws-red-nas-hdd),
[TrueNAS notice on WD SMR with ZFS](https://www.truenas.com/docs/hardware/notices/wdsmr/).

**ZFS over USB3 on 4GB.** Covered above. Faulted pools are expected;
re-seeding is the recovery, not a crisis.

**No client-side encryption in S3.** SSE-S3 means AWS holds the keys.
That is a fine trade for photos and a thinner one for
`/mnt/backups/{kristen,kyle}`, which is 260G of personal documents rather
than family snapshots. If it ever needs revisiting, the narrow fix is an
age-encrypted tarball for just that subset, leaving the photos in plain
files where a family member can reach them.

**Google Photos is a service, not a backup.** Phone photos for both of us
live there and nowhere else. An account lockout, a policy change, or a
lapsed card takes them. A periodic Google Takeout export landing in
`_provisional` would inherit every tier of this design for free. Out of
scope, recorded so it is a known gap rather than an assumption.

**`cp -rn` never prunes.** `arr.nix:126` copies each \*arr's own
`Backups/` directory with `cp -rn` and nothing ever removes anything.
`/mnt/backups/apps/nzbhydra2` has reached 21G. It inflates the pool, the
Pi, and the S3 bill.

**The 216G duplicate.** `/mnt/backups/photos-backup` gets
checksum-verified as a true subset of `/mnt/photos` and only then
deleted, and only after the Pi holds a verified copy. It is the one
destructive step in this whole plan.

## Rollout

Four phases. The ordering matters more than the dates.

### Phase 1: the cloud tier

No hardware, no physical work, all Nix and Terraform. Extend coverage to
`_provisional` and `/mnt/backups`, drop `--delete`, strip delete from the
IAM policy, delete the external HDD leg, keep the RAF files, and add the
staleness plus zpool alerts.

That alone gets us three copies in two places with alerting on both,
before anything gets unboxed.

### Phase 2: the Pi

Runs concurrently with phase 1. Blocked only on confirming the drives.
Build, seed ~1.18 TB, add Pi-side sanoid with the longer retention.

### Phase 3: reclaim

Only after the Pi copy verifies. Checksum and delete the 216G duplicate,
prune nzbhydra2, drop `/var/lib/jellyfin.old-20260611` (3.4G). Takes the
pool back off 80%, which is the cheapest thing we can do about the SMR
resilver risk.

### Phase 4: assurance

The reconciliation job, the ZFS dashboard, the S3 restore script, and the
first real restore drill. Then look at replacing the SMR drives and
adding the third rotating one.

## Open decisions

Not blockers for the design, but each one gates its phase.

**The drives.** Sizes, models, and whether SMART survives the bridge:

```bash
lsblk -o NAME,SIZE,MODEL,TRAN,ROTA
sudo smartctl -i /dev/sda
```

If SMART does not pass through, the existing `smartctl-exporter` timer
sees nothing on these drives and the zpool-health alert becomes the only
signal we have.

**Who pushes to S3.** Recommendation is the Pi, so no AWS credential
exists on tiger and the threat model holds at every tier. tiger is the
simpler option and keeps the existing unit where it is. Not yet decided.

**Pi retention numbers.** Proposed daily 30 / monthly 24 / yearly 10. The
constraint is the invariant, not the specific numbers: Pi retention is
always at least tiger's.

**`_projects/` storage class.** Four YouTube tutorials in Standard-IA.
Move them to Deep Archive, or stop backing up downloadable videos.
