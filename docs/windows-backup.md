# Windows backups into storage/backups

Kristen's Windows laptop mirrors `Desktop`, `Documents`, `Dropbox` and
`Pictures` to tiger with Syncthing. Once the files land in `/mnt/backups`,
they are backed up by the rule in [backup-strategy.md](backup-strategy.md):
tiger snapshots them, pika pulls a second copy, pika pushes an offsite one to
Deep Archive. None of that needs teaching about Windows.

So the only new machinery is a Syncthing instance on tiger to receive, and an
alert for when the laptop stops sending.

## Why Syncthing

The laptop gets touched maybe twice a year, so whatever runs on it has to
start itself, retry itself, and survive being away from home for weeks.
Syncthing does all three as one installed program. It runs at logon, watches
the folders, and catches up whenever it can reach tiger. Nothing on the
laptop is a script.

Files land as plain files, one for one. That matters more than it looks:

- **Versioning is ZFS's job.** sanoid and pika already keep the history. A
  backup tool with its own retention would keep a second history on a pool
  that is already near 80%.
- **Archive formats fight the S3 tier.** `aws s3 sync` re-uploads a file
  whole when it changes. An image backup that merges into one big file every
  night is a full re-upload every night, at 2 MB/s, each version billed for
  180 days. Chunked formats (Kopia, restic, Duplicati) behave better, but
  they need the tool to restore and usually a password, and the S3 tier is
  plain files on purpose.
- **Restore is a copy.** Nothing to install, no password to remember.

What was tried on paper first, and why it lost:

- **robocopy over SMB.** Worked, but it was a `.cmd` file and a scheduled
  task on a machine nobody maintains, and it needed the SMB share and a
  stored credential besides.
- **File History.** Built in and versioned, and the September 2026 updates
  broke it on every current Windows 11 release while it reported "Reconnect
  your drive"
  ([BleepingComputer](https://www.bleepingcomputer.com/news/microsoft/microsoft-september-updates-break-file-history-backup-feature/)).
  That is the exact failure this needs to not have.
- **UrBackup.** Server-side retention as a fresh hardlinked tree per run
  ([manual](https://www.urbackup.org/administration_manual.html)), which the
  S3 sync sees as every file being new.

## What is on tiger

All in `nix/hosts/tiger/configuration.nix`:

- **`windowsBackupDirs`** - the enrollment list. One entry per machine gives
  its directory under `/mnt/backups`, its Syncthing device ID, and the folders
  it sends. The tmpfiles rule, the Syncthing device and folders, the exporter
  and the alert label all follow from it. `device = null` means enrolled but
  not paired yet.
- **`services.syncthing`** - one receive-only folder per entry in `folders`,
  at `/mnt/backups/<dir>/<Folder>`, with folder ID `<dir>-<folder>`. Global
  discovery, local discovery, relays and NAT traversal are off, so it only
  ever talks to the laptop, and only on the LAN. 22000 is open on `enp10s0`.
- **`win-backup-exporter`** - every 15 minutes, asks tiger's Syncthing
  whether the laptop is connected and sharing every one of its folders, and
  whether tiger has nothing left to pull. On a yes it touches
  `/var/lib/win-backup-exporter/<dir>`, and it publishes that file's mtime as
  `windows_backup_last_success_timestamp_seconds`.

Receive-only is the guarantee that nothing flows back. A receive-only folder
never sends its own changes
([folder types](https://docs.syncthing.net/v2.0.0/users/foldertypes.html)),
so whatever happens to the copy on tiger stays on tiger. Send-only on the
laptop is the same rule from the other end.

The flip side is that deletes propagate. Kristen deleting a file deletes it
on tiger within minutes, and the undo is a snapshot. The robocopy plan had
the same deal.

Alerts live in `monitoring-stack/vmalert.nix` under `windows_backup`:

- **`WindowsBackupStale`** at 14 days. Every other backup here alerts at
  36 hours, but this is a laptop that travels, and tiger is only reachable
  from home.
- **`WindowsBackupNeverSucceeded`** for a machine that has never synced,
  waiting 7 days after its directory last changed.
- **`WindowsBackupExporterMissing`** as the absence check on the exporter
  itself.

The success stamp lives on tiger and is written by tiger, so a laptop with a
wrong clock cannot report itself fresh, and a restart at either end does not
reset it.

## Setting up the laptop

Do this at home. tiger is not reachable from anywhere else.

### 1. Check the laptop can reach tiger

tiger is in the DMZ on 10.25.89.0/24 and the LAN is 10.24.89.0/24, so use
the routed name, the same one trex uses:

```powershell
Test-NetConnection tiger.dmz.1ella.com -Port 22000
```

This fails until tiger has been deployed with Syncthing. After that, if it
still fails, stop. Nothing else here matters until it passes.

### 2. Make Dropbox available offline

Dropbox on Windows can keep files online-only, as placeholders that download
when something opens them
([Cloud Files API](https://learn.microsoft.com/en-us/windows/win32/cfapi/build-a-cloud-file-sync-engine)).
Syncthing reads every file to hash it, and reading a placeholder downloads
it, so a folder of placeholders turns the first scan into an uncontrolled
download of the whole account.

Right-click the Dropbox folder in Explorer and choose **Make available
offline**, then check the laptop has the disk for it. In Dropbox's
preferences, set new files to default to available offline too.

### 3. Install Syncthing

Use [Syncthing Windows Setup](https://github.com/Bill-Stewart/SyncthingWindowsSetup/blob/v2.1.0/README.md#non-administrative-current-user-installation-mode),
logged in as Kristen:

```powershell
winget install --id BillStewart.SyncthingWindowsSetup --exact
```

Take the defaults. That is a current-user install: it starts Syncthing hidden
at logon through a scheduled task Setup creates, and it can read her folders
without any permission changes. It checks for Syncthing upgrades every 12
hours and installs them.
Allow the firewall rule when it asks.

The all-users install runs as a Windows service instead, but under its own
account, which then needs `icacls` grants on every folder. Not worth it for a
one-user laptop.

### 4. Turn off everything that is not tiger

Open **Syncthing Configuration Page** from the Start menu. Decline usage
reporting if it asks. Under **Actions > Settings > Connections**, untick:

- Global Discovery
- Local Discovery
- Enable Relaying
- Enable NAT traversal

Save.

### 5. Pair the two ends

On the laptop, **Actions > Show ID**. Put that ID in `windowsBackupDirs` in
`nix/hosts/tiger/configuration.nix`, replacing `device = null`, and deploy
tiger:

```bash
make deploy-rs HOSTNAME=tiger
```

Then get tiger's ID:

```bash
ssh tiger 'sudo -u syncthing syncthing device-id --home=/var/lib/syncthing/.config/syncthing'
```

On the laptop, **Add Remote Device**. Paste tiger's ID, name it `tiger`, and
on the **Advanced** tab set Addresses to `tcp://tiger.dmz.1ella.com:22000`.
Save.

### 6. Accept the folders

Within a minute the laptop shows an offer from tiger for each folder. For
each one:

- **Add**, and check the folder path is the real one,
  `C:\Users\<her>\Documents` and so on. It defaults to the folder's label
  under her home directory, which is right unless Dropbox was moved.
- **Advanced > Folder Type: Send Only.**
- Save.

Pointing a send-only folder at the wrong path is harmless: tiger gets the
wrong directory, and nothing on the laptop is touched.

## Checking it worked

The directory belongs to `syncthing` and is mode 0750, so reading it takes
`sudo`.

```bash
# the files landed
ssh tiger 'sudo ls /mnt/backups/kristen-data/Documents | head'

# tiger counts it as a success (wait for the next 15-minute run)
ssh tiger 'curl -s "http://127.0.0.1:8428/api/v1/query?query=windows_backup_last_success_timestamp_seconds" | jq .'

# a snapshot picked it up
ssh tiger 'ls /mnt/backups/.zfs/snapshot/ | tail -1'

# pika has the second copy, after its daily syncoid
ssh pika 'sudo ls /tank/backups/kristen-data'

# and the offsite one, after pika's 06:00 push
aws s3 ls s3://ondy-archive-resolved-pug/backups/kristen-data/ --recursive | head
```

Then do a restore. Delete a file on the laptop, wait for it to vanish on
tiger, and pull it back out of `/mnt/backups/.zfs/snapshot/`. A backup nobody
has restored from is a guess.

## When it breaks

**`WindowsBackupStale` fires.** A two-week trip explains it. So does
Syncthing not starting at logon, a folder paused on the laptop, or a full
pool. Check the laptop's web UI first: every folder should read Up to Date,
and tiger should read Connected. On tiger, `journalctl -u syncthing`.

**`WindowsBackupNeverSucceeded` fires.** Either `device` is still null, or
the laptop never accepted every folder. The exporter wants the laptop sharing
all of them before it counts a success, so one unaccepted or paused folder
holds the whole machine at zero.

**A folder says Out of Sync on tiger.** `journalctl -u syncthing` on tiger
names the file. A full pool is the likely cause.

**A cull on the laptop deleted something wanted.** Recover from
`/mnt/backups/.zfs/snapshot/` on tiger, which keeps 31 dailies, reading it
with `sudo`. pika keeps the same data readonly for far longer, at daily 60,
monthly 36, yearly 15. Syncthing will not carry the file back, because
tiger's folders are receive-only, so copy it to trex and hand it over.

**The laptop died.** This is a plan, not a drill anyone has run. On the new
laptop, install as above, swap the new device ID into `windowsBackupDirs`,
and accept each folder as **Receive Only** first. tiger offers everything it
holds, so the new laptop pulls the lot. Once every folder reads Up to Date,
switch each to **Send Only**.

## Adding a second machine

Add an entry to `windowsBackupDirs` with its directory, device ID and
folders. The directory, the Syncthing device and folders, the exporter, the
metric label and every alert follow from the entry. Then repeat the laptop
steps on the new machine.
