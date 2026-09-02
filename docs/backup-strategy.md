# Backup strategy

Three copies, two places, one offsite. tiger holds the live primary, pika
pulls a second local copy, and S3 Glacier Deep Archive holds the offsite
one.

This document is the design, the reasoning, and what is actually running.
Anything not yet built is under [What is left](#what-is-left).

State as measured 2026-08-04, with pool capacity and `storage/photos`
re-measured 2026-09-01. The numbers go stale; the shape does not.

## Scope

In scope, and the only things in scope:

- `storage/photos`, 513G used, 327G referenced. The curated photo library
  plus `_provisional`.
- `storage/backups`, 650G used, 319G referenced. `kristen`, `kyle`,
  `videos`, `apps`.
- `storage/projects`, working video projects. The Resolve trees under
  `~/resolve` on trex plus the Resolve project library, pushed by
  `backup-resolve-projects`. Tier 1 and tier 2 only.

That is ~1.12 TB on pika once tiger's snapshot history comes along, and
637 GB of current files across 157,301 objects for the S3 tier.

`storage/photos` was 513G used and 327G referenced on 2026-08-04. It is 963G
and 749G now, which is most of why the pool moved from 80% to 85% in a month
and is the number to watch before adding anything else here.

### Tier 3 is not universal

`storage/projects` stops at pika. It is the first dataset here with a
deliberate hole in the offsite copy, so the reason is recorded rather than
left to be re-derived:

- It is hundreds of GB of camera footage against a 24.6 Mbps uplink capped
  at 2 MB/s. The 222G project that opened this dataset is a 31-hour push on
  its own, and it would recur every time a card is dumped.
- Restore economics invert. Egress dominates the ~$54 figure below, and
  video is the one thing here that is bulky enough to make that a real bill
  rather than a rounding error.
- The loss is bounded and known. Losing tiger and pika together loses the
  footage. Photos and documents are irreplaceable; a trip's rushes are
  painful, and that is a different word.

The mechanism is the absence of an `s3-archive-push` unit, not a filter. The
push units are declared per dataset in `pika/configuration.nix`, so a
dataset nobody declares is a dataset that never leaves the house. There is
no exclusion list to keep in sync, which is the same property the dataset
boundary buys everywhere else in this document.

Out of scope, deliberately:

- **`storage/media`** (4.34T). Re-acquirable. Not worth the drives.
- **`storage/immich`** (334G). Immich is a read-only view of the curated
  archive through `externalLibraryPaths`, which `immich.nix:118-121`
  enforces with `ReadOnlyPaths`. It holds no originals, so it needs no
  backup. It is a projection of tier 1, not a source.
- **tiger's root disk.** jellyfin, navidrome, sabnzbd, prowlarr, the
  \*arrs, and the monitoring stack are all rebuildable from the flake.
- **`storage/scratch-big`, `scratch/scratch`, `storage/data`.** Scratch is
  scratch, and `storage/data` is empty.
- **Ingest.** Google Photos handles phone capture. Camera cards reach the
  library through `backup-photos` and `photos-promote`, run by hand.

### The one rule that makes this work

The backup boundary is the dataset. Nothing gets backed up because it is
important. It gets backed up because it lives in `storage/photos`,
`storage/backups` or `storage/projects`.

Anything new that matters has to be made to land in one of those three
datasets. That is a deliberate constraint, not a limitation. It means the
question "is this backed up?" has a one-word answer you can check with
`zfs list`, instead of an audit.

The dataset now answers a second question the same way. It sets not just
whether a thing is backed up but how far it travels, because the tier 3
push is declared per dataset. "How many copies does this have?" is still
`zfs list` plus one glance at the push units, never a per-directory audit.

### Writers into storage/backups

A Windows PC mirrors `Documents`, `Pictures` and `Desktop` into
`/mnt/backups/kristen-data` over SMB, on a nightly scheduled task. See
[windows-backup.md](windows-backup.md).

It gets one thing the other writers do not: its own freshness alert. Every
other tier here is driven by a systemd timer on a host we control, so
absence is measurable from the inside. The Windows push is not, so the
client writes a heartbeat file on success and tiger alerts on its age. Any
future writer that lives off-fleet needs the same treatment.

### Writers into storage/projects

One, `backup-resolve-projects` on trex, run by hand. It mirrors two trees:
`~/resolve` to `/mnt/projects/resolve`, and Resolve's project library to
`/mnt/projects/resolve-project-library`.

Both, together, or neither is worth having. `~/resolve` holds the footage
and the shot lists; the library holds the timelines, grades and bin
structure that reference them, and Resolve keeps it under Application
Support rather than in the project folder. Backing up the project folder
alone loses every edit decision ever made, and nothing about the on-disk
layout hints at that. Hence one command rather than two rsync invocations
someone has to remember to pair.

It mirrors with `--delete`, so cleaning up a finished project locally
removes it from tiger on the next run, after which it ages out on the
retention above: recoverable for about a month, then gone. That is the
intended lifecycle for a dataset on a pool at 85%, and it is why the script
refuses to run against a missing or empty source. `--delete` from an empty
tree is a one-command wipe of the copy that exists to survive exactly that
class of mistake.

It also skips the library, loudly and with a non-zero exit, while Resolve is
running. The library is a live SQLite database, and a copy taken with it
open restores as a corrupt project, which is worse than no copy because it
still looks like a backup. The footage tree is plain files and syncs either
way, so a run with Resolve open is a partial success reported as a failure,
never a silent one.

Being run by hand makes it the second writer here whose absence is not
measurable from the inside. It has no freshness alert yet, for the reason
in [What is left](#what-is-left).

## Architecture

```
tiger (DMZ)                  pika (LAN)                  AWS
-----------                  ----------                  ---
storage/photos    --send-->  tank/photos     --sync-->   Deep Archive
storage/backups   --send-->  tank/backups    --sync-->   Deep Archive
storage/projects  --send-->  tank/projects        x       (stays in house)

raidz1, 3x 4TB SMR           mirror, 2x 6TB SATA         versioned
sanoid, snapshots            sanoid, prune only          put-only IAM
85% full                     NVMe root, on UPS           no --delete
```

Read the arrows as trust, not just data. Every arrow is initiated by the
host on its right.

tiger holds no credential for pika and no credential for AWS. pika pulls
from tiger and pushes to S3. If tiger is compromised, the blast radius is
tiger.

That property is the reason the topology is worth the second host at all,
and it is the thing to check first when changing anything here.

## Tier 1: tiger

tiger does not get restructured. You do not rebuild the only writable copy
of the data.

Sanoid runs at `tiger/configuration.nix:98`, covering `storage/backups`
(hourly 4, daily 31, monthly 24, yearly 10), `storage/photos` (daily 8,
monthly 12, yearly 10) and `storage/projects` (hourly 24, daily 30, monthly
2, no yearly). `autoScrub` is on at `:95`, `autoSnapshot` off at `:96`.

`storage/projects` is the only one without a yearly tier, and the asymmetry
is deliberate. A video project is finite: it ships, the footage gets
deleted, and a yearly snapshot would pin those blocks for a year on a pool
already at 85%. Its retention is sized to survive an accident, not to
archive. Hourly is there for the few hundred KB of edit decisions that
change every session, and costs almost nothing for the footage beside them,
since unchanged blocks are shared between snapshots rather than copied.

`storage/photos` carries `yearly = 10` so that pika's own `yearly = 10` has
something to hold. sanoid on pika prunes and never creates, so a retention
tier tiger does not produce is a tier pika cannot keep.

The unsnapshotted datasets are a decision, recorded here so it reads as
one: `storage/media` and `storage/scratch-big` are replaceable,
`storage/data` is empty, `scratch/scratch` is scratch, and
`storage/immich` is a projection.

The pools were created by hand and are not declared in Nix. The `disko`
input was removed in `e94efb4e`, so this stays manual, and any new dataset
needs the same treatment.

A new dataset also needs its root chowned once. The `systemd.tmpfiles` rule
that owns the mountpoint runs before the mount on the activation that first
introduces it, so it lands on the directory the mount then covers and the
dataset root stays `root:root`. Boot orders it correctly, so it happens once
per dataset. `systemd-tmpfiles --create --prefix=<mountpoint>` settles it
without a reboot.

What is recorded is partial: the `zfs create` for `storage/immich` at
`tiger/configuration.nix:276`, and the `acltype=posixacl` that
`storage/photos` needs at `:400-401`. The `zpool create` that made
`storage` itself is written down nowhere. Rebuilding tiger means
reconstructing it from `zpool history` on a pool that, in the scenario
where you need this, no longer exists. Worth fixing before it is needed.

### Delegating send to pika

Pull needs no write permission on tiger at all:

```bash
zfs allow -u svc.syncoid send,hold,release storage/photos
zfs allow -u svc.syncoid send,hold,release storage/backups
zfs allow -u svc.syncoid send,hold,release storage/projects
```

That runs as a systemd unit at `tiger/configuration.nix:207` rather than by
hand, because `zfs allow` lives in dataset properties and a recreated
dataset would silently drop it. It is idempotent, so it reapplies on every
activation.

Snapshot creation stays with sanoid on tiger, so syncoid runs with
`--no-sync-snap` and never needs the `snapshot` verb.

## Tier 2: pika

An ODROID-H2 on the LAN. Quad-core Celeron J4105, 32GB of DDR4, a 500GB
NVMe root, and two SATA3 ports fed from the board's own 15V supply. One of
three boards that ran as `w1`, `w2` and `w3` until `58aed155` retired them,
which means an identical spare sits on the shelf and a dead backup host is
a ten minute swap rather than a project.

The pool is a mirror of two shucked WDC WD60EDAZ-11U78B0, 6TB 5400rpm.
1.12T used of 5.3T. Board and both drives are on a UPS: brownout during a
write is the cleanest way to fault a pool, and one 15V brick carries all of
it, so there is exactly one thing to protect.

The J4105 has no ECC support. Neither did the Pi this plan replaced, and
ZFS on non-ECC memory is no worse off than any other filesystem would be.
Recorded rather than solved.

Provisioning is not in Nix. The full sequence, from the nixos-anywhere
kexec through partitioning to `zpool create`, is recorded in the comment at
the foot of `pika/configuration.nix:400`.

### Isolation comes from the router

tiger sits in the DMZ. pika sits on the LAN. The DMZ cannot initiate
connections to the LAN.

That is a stronger guarantee than an SSH forced-command, because it is
enforced by a device that is not the one we are defending against. pika
opens every connection: syncoid pulls from tiger, vmagent and promtail push
metrics and logs to tiger, and the S3 sync goes straight out.

pika also takes nothing from tiger as a binary substituter.
`deployment_target.nix:102` hands every NixOS node
`trusted-substituters = [ "ssh://svc.deploy@tiger.dmz.1ella.com" ]`, and
`pika/configuration.nix:141` forces that list empty. pika is the host that
insures against tiger, so it accepts no store paths from it.

### Two flags that would undo all of it

**Never `zfs recv -F`. Never `syncoid --force-delete`.**

Both make the receiving side roll back or destroy datasets to match the
source. A compromised tiger cannot reach pika, but it can absolutely answer
a request pika made. Those two flags turn that answer into a wipe of the
second copy.

The NixOS syncoid module defaults to neither, and nothing in
`pika/configuration.nix` adds them.

### Received datasets are readonly

`recvOptions = "o readonly=on"` on both legs, set on receive rather than by
hand afterwards, so it is true from the first stream rather than from
whenever someone remembered.

This one has a trap worth recording. A property named in `recvOptions` must
also appear in `localTargetAllow`, or `zfs recv` logs a permission error per
stream, skips the property, and still exits 0. The receive succeeds, the
dataset is writable, and nothing reports it. `localTargetAllow` is trimmed
to `create,mount,readonly,receive,rollback`: the module default also grants
`change-key`, `compression` and `mountpoint`, and nothing here sends raw
encrypted or raw compressed streams.

Verify with `zfs get readonly tank/photos tank/backups`, not by reading the
config.

### Retention must be longer on pika than on tiger

The invariant: pika retention >= tiger retention, always.

```
              tiger                       pika
tank/backups  hourly 4, daily 31,         hourly 4, daily 60,
              monthly 24, yearly 10       monthly 36, yearly 15
tank/photos   daily 8, monthly 12,        daily 30, monthly 24,
              yearly 10                   yearly 10
tank/projects hourly 24, daily 30,        hourly 24, daily 60,
              monthly 2, no yearly        monthly 3, no yearly
```

`tank/projects` holds no yearly tier because tiger creates none, and a tier
tiger does not produce is a tier pika cannot keep.

sanoid on pika has `autosnap = false`. It prunes and never creates. If it
ever prunes faster than tiger does, tiger dropping an old snapshot cascades
into the backup and the second copy quietly becomes a mirror of the first
rather than a longer history of it.

### A received dataset does not mount itself

`zfs recv` leaves a newly created dataset unmounted even with `canmount=on`
and a mountpoint set. It mounts on the next boot, or when someone runs
`zfs mount`.

That matters because `aws s3 sync` against an empty mountpoint is
indistinguishable from a healthy run that had nothing to do. Both push and
reconcile check `zfs get mounted` first and exit non-zero, which turns the
silent case into a failed unit and a firing alert.

Seen once for real, on the first receive of `tank/backups`.

## Tier 3: Glacier Deep Archive

Bucket `ondy-archive-resolved-pug`, two prefixes, `photos/` and
`backups/`. Defined in `tf/archive-backup.tf`.

Plain files, `aws s3 sync`, no restic.

That is a deliberate trade. restic would give us client-side encryption,
dedup, append-only snapshots, and real integrity verification. What it
takes away is the thing that matters most for family photos: anyone with
the bucket credentials and a browser can get them out. An encrypted repo
needs the tool plus a password that has to outlive me.

For irreplaceable photos, recoverable-by-a-non-technical-person wins. Same
reasoning drives SSE-S3 over client-side or SSE-C: a key that must survive
the event this bucket exists for is the same problem twice.

One bucket rather than two. The prefixes have identical policy, get
restored together, and share a credential. Two buckets with identical
policy is two things to drift.

### Storage class is set on the PUT

`s3-archive-push` passes `--storage-class DEEP_ARCHIVE`. There are no
lifecycle transition rules anywhere in `tf/archive-backup.tf`.

Transitions have refused to move objects under 128 KB since September 2024
([lifecycle transition constraints](https://docs.aws.amazon.com/AmazonS3/latest/userguide/lifecycle-transition-general-considerations.html#lifecycle-configuration-constraints)).
Under a transition-based rule every sidecar and small JPEG would sit in
Standard forever at 23x the price, and nothing would report it. Setting the
class at PUT time also avoids a transition request per object.

### Two credentials, split on one verb

A simple DELETE against a versioned bucket cannot destroy anything. It
inserts a delete marker and the data survives as a noncurrent version.
Permanent removal requires DELETE with a `versionId`, gated by
`s3:DeleteObjectVersion`
([deleting object versions](https://docs.aws.amazon.com/AmazonS3/latest/userguide/DeletingObjectVersions.html#delete-request-use-cases)).

So no host in the fleet holds `s3:DeleteObjectVersion`.

| Credential          | Verbs                            | Used by                    |
| ------------------- | -------------------------------- | -------------------------- |
| `svc.archive-push`  | ListBucket, GetObject, PutObject | daily push, restore drills |
| `svc.archive-prune` | ListBucket, DeleteObject         | weekly prune               |

A fully compromised pika can write 157,301 delete markers and destroy zero
bytes. Permanent removal is exclusively the lifecycle rule, running as S3
rather than as anything holding a key.

MFA Delete would give a similar property and was considered. It is
incompatible with having any lifecycle configuration at all
([lifecycle configuration constraints](https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-lifecycle-mgmt.html)),
and the noncurrent expiry below is what keeps this affordable, so the IAM
split does the job instead.

### Pruning

`noncurrent_version_expiration` at 180 days, plus
`expired_object_delete_marker` and a 7 day
`abort_incomplete_multipart_upload`.

180 rather than 90 because Deep Archive bills a 180-day minimum and charges
a prorated early-deletion fee for anything removed sooner
([Glacier pricing considerations](https://docs.aws.amazon.com/AmazonS3/latest/userguide/lifecycle-transition-general-considerations.html#glacier-pricing-considerations)).
Expiring at 90 costs exactly the same and buys half the undelete window.

The push never passes `--delete`. Orphan removal is a separate weekly job,
`s3-archive-reconcile --prune`, with the prune credential and a safety
threshold: if orphans exceed 5% of the objects in the bucket it refuses,
sets `s3_reconcile_prune_blocked`, and exits non-zero so the unit fails.

A large orphan set almost never means you deleted a lot. It means the
source listing is wrong, and acting on it would propagate that to the one
copy that survives the house.

The prune runs on pika, not by hand. A manual reconciliation is a
reconciliation that never happens, and this repo already has the receipt
for that: `photos-fanout.sh` skipped its external HDD leg on every run for
months, exit code 0 each time, because best effort with no alerting is
indistinguishable from not trying.

### Bandwidth

The uplink measures 24.6 Mbps, so the push is capped at 2 MB/s in
`/etc/aws/s3-archive-push.conf`. Saturating it fills the modem's buffer and
takes interactive latency with it.

It is a config file rather than a unit environment variable because awscli
has no env var for `max_bandwidth`. Measured effect on a concurrent speed
test: 2.94 MB/s down to 2.30 MB/s.

The seed is therefore slow on purpose. 637 GB at 2 MB/s is about four
days.
Steady-state daily deltas are minutes.

### Schedule

| Unit                       | When           |
| -------------------------- | -------------- |
| `syncoid-storage-*`        | daily, 00:00   |
| `s3-archive-push-photos`   | daily, 04:00   |
| `s3-archive-push-backups`  | daily, 06:00   |
| `s3-archive-prune-photos`  | Sundays, 05:00 |
| `s3-archive-prune-backups` | Mondays, 05:00 |

Fixed offsets rather than `After=` ordering on syncoid. A stuck pull should
delay the push, not cancel it. Two hours between the pushes so the two
directory walks do not contend for the uplink.

### Cost

637 GB of current files across 157,301 objects. Sizes here are binary GB,
which is how S3 measures storage.

|                     | Deep Archive                         |
| ------------------- | ------------------------------------ |
| Storage             | ~$0.67/month                         |
| Full restore        | ~$54                                 |
| Minimum retention   | 180 days                             |
| Per-object overhead | 40 KB (8 KB of it at Standard rates) |

Storage breaks down as $0.63 for the data, $0.03 for the 8 KB of
Standard-rate metadata per object, and half a cent for the rest. Restore is
$1.59 of bulk retrieval, $3.93 of retrieval requests across 157,301
objects, and ~$48 of egress after the first 100 GB. The egress dominates,
which is worth knowing before designing anything around partial
restores.

Sources: [AWS S3 pricing](https://aws.amazon.com/s3/pricing/) for the
180-day minimum and the 40 KB metadata charge,
[Deep Archive rates](https://www.usage.ai/blogs/aws/storage-cost/glacier-deep-archive-pricing/)
for $0.00099/GB-month storage and $0.0025/GB bulk retrieval.

At $0.67/month, cost is not what constrains this tier. Recoverability is.

## Verification

Four layers, all in `monitoring-stack/vmalert.nix`.

### Why none of it watches an exit code

`SystemdServiceFailed` looks like coverage and is not. A `oneshot` that
never runs never enters `failed`. A disabled timer, a misfire, a host that
was down at the trigger: all invisible.

Every backup alert here is absence-based. It alerts on the lack of a fresh
success, not on the presence of an error.

That also fixes the ordering within each group. Absence rules come before
staleness rules, because a missing dataset or an empty one deletes the
timestamp series outright, and `time() - <nothing>` matches nothing at all
rather than firing.

### 1. Replication freshness, group `backup_replication`

| Rule                           | Fires when                                 |
| ------------------------------ | ------------------------------------------ |
| `BackupReplicaDatasetMissing`  | no snapshot metrics for a pika dataset, 1h |
| `BackupReplicaEmpty`           | dataset exists, zero snapshots, 2h         |
| `BackupReplicaStale`           | newest snapshot older than 36h             |
| `BackupReplicaCriticallyStale` | newest snapshot older than 72h             |
| `BackupSourceSnapshotsStale`   | tiger's own snapshots older than 36h       |

Freshness is measured the same way on both ends, so the pair says which end
broke. Stale on pika alone is replication. Stale on both is sanoid on
tiger.

Metrics come from `zfs-snapshot-exporter` in
`deployment_target.nix:285`, through the node_exporter textfile collector.

### 2. Pool health and scrub age, group `zfs_storage`

`ZpoolNotOnline`, `ZpoolScrubStale` (45 days), `ZpoolNeverScrubbed`, and
`ZpoolScrubMetricMissing`.

That last one is the absence check on the absence check: a host reporting
`zfs_pool_health` but no `zfs_pool_scrub_end_timestamp_seconds` has lost
`ZpoolScrubStale` without anyone noticing.

Note the metric rename recorded in `DASHBOARD_CONVENTIONS.md:429`:
`zfs_zpool_*` became `zfs_pool_*`, and the `poolname` label became `pool`.
Easy to write a rule that silently matches nothing.

### 3. Offsite freshness and reconciliation, group `offsite_archive`

| Rule                           | Fires when                                    |
| ------------------------------ | --------------------------------------------- |
| `S3ArchivePushNeverSucceeded`  | a prefix has no success timestamp at all, 24h |
| `S3ArchivePushStale`           | last clean sync older than 36h                |
| `S3ArchivePushCriticallyStale` | last clean sync older than 96h                |
| `S3ArchiveObjectsMissing`      | source files with no object in the bucket, 6h |
| `S3ArchivePruneBlocked`        | orphan threshold refused a prune              |
| `S3ReconcileStale`             | no comparison in 14 days                      |

`S3ArchiveObjectsMissing` is the one that earns the tier. It is the failure
where the sync believes it is current and the offsite copy is not, which is
exactly what went unnoticed for a year under the old fanout arrangement.

These rules go quiet during an initial seed, which legitimately runs for
days before recording a first success. Silence them, do not retune them.

### 4. Drills

**Quarterly:** pick a random directory, restore it from pika, checksum it
against tiger. Record that it happened.

**Annually:** `aws s3api restore-object` with the bulk tier on about five
random objects, then verify checksums. Costs pennies. The point is to learn
that the archive tier works before the day it has to.

Bulk retrieval is 48 hours. That is a bad thing to discover mid-disaster.

Neither drill has been run yet. Until one has, everything above is a
hypothesis.

## Restore runbook

### A file or directory got deleted

Recover from a tiger snapshot. `storage/backups` keeps hourly 4, daily 31,
monthly 24, yearly 10.

```bash
ls /mnt/photos/.zfs/snapshot/
cp -a /mnt/photos/.zfs/snapshot/autosnap_2026-07-24_00:00:03_daily/personal/photos/archive/<dir> \
      /mnt/photos/personal/photos/archive/
```

Older than tiger's retention, pika holds it: daily 60, monthly 36, yearly
15 for `tank/backups`, against tiger's 31, 24 and 10. Browse it the same
way under `/tank/backups/.zfs/snapshot/`.

Older than pika's retention, only S3 has it, and only if the file survived
long enough to be pushed at all. The offsite tier keeps deleted objects for
180 days after they go noncurrent, which is a different clock from either
snapshot policy.

### A dataset got corrupted on tiger

Reverse the syncoid direction. Pull from pika back to tiger, into a new
dataset name, verify, then swap mountpoints. Do not receive over the live
dataset.

`readonly=on` on pika does not get in the way: it blocks writes to the
filesystem, not `zfs send`. What it does mean is that pika can never be
made the writable primary in place. Restoring is always a send back to
tiger, never a promotion of pika.

### tiger is gone

Rebuild tiger from the flake, create the pool by hand, then syncoid from
pika to tiger. The `zpool create` is not recorded anywhere; see tier 1
above for what that costs you here.

~1.12 TB over GbE. The seed in the other direction sustained 103 MB/s, so
budget around three hours. The network is the constraint, not the drives.

### tiger and pika are both gone

Deep Archive. Restore requests first, then wait, then download.

```bash
aws s3api list-objects-v2 --bucket "$BUCKET" --prefix "photos/" \
  --query 'Contents[].Key' --output text | tr '\t' '\n' > keys.txt

while read -r k; do
  aws s3api restore-object --bucket "$BUCKET" --key "$k" \
    --restore-request '{"Days":14,"GlacierJobParameters":{"Tier":"Bulk"}}'
done < keys.txt
```

48 hours for bulk. Then `aws s3 sync` normally; restored objects read like
any other. Budget ~$54 for the full 637 GB.

The `svc.archive-push` credential can do this: it holds `GetObject` and
`GetObjectVersion` for exactly this reason.

This is still a shell snippet in a document rather than a script in the
repo. Write it before we need it, not during.

## Risks

**tiger's pool is the weakest link, not the strongest.** All three drives
in `storage` are `WDC_WD40EFAX`. The EFAX code at 2-6TB is WD Red DM-SMR. A
resilver is sustained-write, which is precisely the workload where DM-SMR
throughput collapses, and raidz1 carries zero redundancy for the whole
window. The pool is at 85% as of 2026-09-01, past the 80% where ZFS
allocation starts to suffer, with 967G free.

`storage/projects` was added on top of that, knowingly. 222G of it is one
trip, which takes the pool to roughly 87%. The dataset carries no yearly
tier and a two-month monthly tier specifically so that deleting a finished
project returns the space on the timescale of weeks rather than years, but
that is mitigation, not a fix. Video is now competing with the photo library
for the last terabyte of a pool that should not be resilvered, and the CMR
replacements below stop being a long-term item at the point where the next
trip does not fit.

That inverts the obvious reading of this architecture. pika is not a
nice-to-have second tier. It is insurance against a primary that is more
fragile than it looks, which is also why tiger does not get restructured.
Long-term fix is CMR replacements.

Sources:
[WD Red SMR model codes](https://david.gardiner.net.au/2021/07/ws-red-nas-hdd),
[TrueNAS notice on WD SMR with ZFS](https://www.truenas.com/docs/hardware/notices/wdsmr/).

**pika's drives are unconfirmed.** `WDC WD60EDAZ-11U78B0`, shucked from WD
externals. The EDAZ suffix is not on WD's SMR disclosure list, but it has
not been positively confirmed as CMR either. The 650G seed sustained 103
MB/s of sequential write with no collapse, which is encouraging and not
conclusive: sequential write is SMR's good case. Confirm against WD's
current list before treating the mirror as a resilver-safe tier.

**No client-side encryption in S3.** SSE-S3 means AWS holds the keys. That
is a fine trade for photos and a thinner one for
`/mnt/backups/{kristen,kyle}`, which is personal documents rather than
family snapshots. If it ever needs revisiting, the narrow fix is an
age-encrypted tarball for just that subset, leaving the photos in plain
files where a family member can reach them.

**Google Photos is a service, not a backup.** Phone photos for both of us
live there and nowhere else. An account lockout, a policy change, or a
lapsed card takes them. A periodic Google Takeout export landing in
`_provisional` would inherit every tier of this design for free. Out of
scope, recorded so it is a known gap rather than an assumption.

**`cp -rn` never prunes.** `arr.nix:126` copies each \*arr's own `Backups/`
directory with `cp -rn` and nothing ever removes anything.
`/mnt/backups/apps/nzbhydra2` has reached 21G. It inflates the pool, pika,
and the S3 bill.

**One offsite copy, one region.** The archive bucket is in a single AWS
region under a single account. An account-level event takes the whole tier.
Accepted: the second local copy covers the failure modes that are actually
likely, and a second cloud provider is more moving parts than the risk
justifies.

**Snapshots pin deleted blocks.** Deleting 216G from `storage/backups`
moved `USED` not at all, because every snapshot holding those blocks still
references them. Space comes back as those snapshots age out, up to 31 days
later for daily and years for yearly. Plan reclamation on that timescale,
not on the timescale of the `rm`.

## What is left

**Retire the old bucket.** `my-photo-backup-archive-holy-mink` still holds
the only finished offsite copy, so it stays until the new bucket completes
one clean push of both prefixes.

**Remove `photos-fanout` from tiger.** The unit at
`tiger/configuration.nix:294` still runs nightly against the old bucket,
and `photos_backup_aws_credentials` at `:1201` is the last AWS credential
on the host that faces the internet. Removing both is the point of moving
the push to pika. Blocked on the item above.

**Write the S3 restore script.** The runbook section above is a snippet.

**Run the first drill.** Both kinds. Until then this document describes a
design, not a demonstrated capability.

**Freshness for `backup-resolve-projects`.** It is run by hand, so its
absence is not measurable from the inside, which is the same hole the
Windows push has. The Windows fix does not port directly: that push is
nightly, so a heartbeat older than a day is unambiguously a fault. This one
legitimately does not run for weeks between projects, so a naive staleness
alert would fire through every gap and get silenced, which is worse than no
alert.

The existing replication rules do not cover it either. sanoid keeps
snapshotting `storage/projects` whether or not anything new lands in it, so
`BackupReplicaStale` stays quiet while the laptop copy drifts arbitrarily
far ahead. Nothing currently reports "you have been editing for a week and
never pushed."

The shape that probably works is a heartbeat on the trex side, compared
against the mtime of the newest file in `~/resolve`, alerting only when the
laptop holds work the backup does not. That measures the thing that matters
instead of the clock. Recorded rather than built, and worth doing before the
next trip.

**The `zfs-storage` Grafana dashboard.** `DASHBOARD_CONVENTIONS.md:160`
lists it. It was never built.

**A rotating offline drive.** A mirror covers a drive dying. It does not
cover the board's PSU, a mistyped `zfs destroy`, or a fire. The answer is a
third drive that gets synced, detached, and stored elsewhere. Two SATA
ports means it attaches over USB3 and sits outside the pool at rest, which
is fine for a monthly job.

When it arrives it needs its own staleness alert. "Offline copy older than
N days" has to page, or the rotation quietly stops happening and we will
not find out.

**`mbuffer` on tiger.** syncoid inserts `mbuffer` on whichever side has it.
pika has it, tiger does not, so the send side runs unbuffered. Compression
was measured and dropped from scope: `compressratio` on these datasets is
1.00x.
