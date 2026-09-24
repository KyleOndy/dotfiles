# Windows backups into storage/backups

A Windows PC mirrors a few directories to tiger over SMB. Once the files land
in `/mnt/backups`, they are backed up by the rule in
[backup-strategy.md](backup-strategy.md): tiger snapshots them, pika pulls a
second copy, pika pushes an offsite one to Deep Archive. None of that needs
teaching about Windows.

So the only new machinery is a share the PC can write to, and an alert for
when the PC stops writing.

## What is on tiger

All in `nix/hosts/tiger/configuration.nix`:

- **`tiger-kristen-data`** - an SMB share on `/mnt/backups/kristen-data`,
  scoped to that one subdirectory. The client mirrors with `/MIR`, so the
  share can delete anything under its path. Rooting it at `/mnt/backups`
  would put `kyle/`, `videos/`, `apps/` and the 185G in `kristen/` inside
  that blast radius.
- **`kristen`** - a POSIX account with no password and no shell. It exists so
  `force user` and NSS have something to resolve.
- **`windowsBackupDirs`** - the enrollment list. One entry gives a directory
  and an alert label.
- **`win-backup-exporter`** - reads the mtime of each `_heartbeat` hourly and
  publishes `windows_backup_last_success_timestamp_seconds`, plus the
  directory mtime as a grace anchor.

Alerts live in `monitoring-stack/vmalert.nix` under `windows_backup`: stale at
36h, critical at 72h, a never-ran rule that waits 7 days after the directory
appears, and an absence check on the exporter itself.

The heartbeat is not seeded on tiger. `systemd-tmpfiles` refuses to create a
file across an ownership change, and `/mnt/backups` is owned by kyle while
these directories are owned per-machine:

```
Detected unsafe path transition /mnt/backups (owned by kyle) ->
/mnt/backups/kristen-data (owned by kristen)
```

That split is worth keeping. A machine that never ran reads 0 and a machine
that stopped reads stale, so the two failures get two alerts.

The heartbeat is what makes this work. tiger initiates nothing, so a scheduled
task that quietly stops leaves no failed unit to notice. The client writes the
file only after a clean run, and it writes it over SMB, so the timestamp is
tiger's clock rather than the PC's.

## Setting up the PC

### 1. Check the PC can reach tiger

tiger is in the DMZ on 10.25.89.0/24 and the LAN is 10.24.89.0/24. `nmbd` is
off and mDNS does not cross that boundary, so network browsing will not find
tiger. Use the routed name, the same one trex uses:

```powershell
Test-NetConnection tiger.dmz.1ella.com -Port 445
```

If that fails, stop. Nothing else here matters until it passes.

### 2. Store the credential

Get the password out of sops on a machine that has the key:

```bash
sops -d --extract '["smb_kristen_password"]' nix/secrets/secrets.yaml
```

Then on the PC, logged in as the account the scheduled task will run as:

```
cmdkey /add:tiger.dmz.1ella.com /user:kristen /pass
```

It prompts for the password. Windows stores it DPAPI-encrypted under that
user's profile, which is why the password never goes in the script.

### 3. Install the script

Save as `%LOCALAPPDATA%\tiger-backup.cmd`:

```bat
@echo off
setlocal

set DEST=\\tiger.dmz.1ella.com\tiger-kristen-data
set LOG=%LOCALAPPDATA%\tiger-backup.log
set OPTS=/MIR /FFT /XJ /R:1 /W:5 /NP /NDL /LOG+:"%LOG%"

del /q "%LOG%" 2>nul

robocopy "%USERPROFILE%\Documents" "%DEST%\Documents" %OPTS%
if errorlevel 8 goto fail
robocopy "%USERPROFILE%\Pictures"  "%DEST%\Pictures"  %OPTS%
if errorlevel 8 goto fail
robocopy "%USERPROFILE%\Desktop"   "%DEST%\Desktop"   %OPTS%
if errorlevel 8 goto fail

echo %DATE% %TIME% > "%DEST%\_heartbeat"
exit /b 0

:fail
echo MIRROR FAILED, heartbeat not updated >> "%LOG%"
exit /b 1
```

Every flag earns its place:

- **`/FFT`** - the target is ZFS behind Samba, not NTFS. Without 2-second
  timestamp granularity robocopy sees a mismatch on every file and recopies
  the whole tree every night.
- **`/XJ`** - Windows user profiles carry junction points that loop.
- **`/R:1 /W:5`** - the default is a million retries at 30 seconds each. One
  locked file otherwise hangs the job for years.
- **`if errorlevel 8`** - robocopy returns 0-7 for success (1 means files were
  copied). Task Scheduler reads anything nonzero as failure, so the wrapper
  translates. `errorlevel N` means "N or greater".

Two things about the script that are load-bearing and easy to undo by
tidying it up:

- Each directory mirrors into its own subdirectory, never into `%DEST%`
  itself. `_heartbeat` sits at the share root, so pointing `/MIR` at the root
  would delete it on every run.
- The heartbeat is written last, and only on success. Writing it earlier
  reports a mirror that did not happen.

Add `/XF *.pst *.ost` if desktop Outlook is in use. Those files are always
open and always large, so they will never copy and will fail every run.

### 4. Dry run it

Add `/L` to `OPTS`, run the script by hand, and read the log. It should
propose creates and zero deletes. `/MIR` against a directory that already had
content is the one way this setup destroys something, so do not skip this.

Take `/L` back out when the log looks right.

### 5. Schedule it

Task Scheduler, new task:

- **Trigger** - daily, and tick "Run task as soon as possible after a
  scheduled start is missed". The PC will be off sometimes. This is the
  Windows version of `Persistent = true` on a systemd timer.
- **Security** - "Run whether user is logged on or not", as the same account
  that ran `cmdkey`. Do not map a drive letter: a non-interactive session has
  none, which is why the script uses the UNC path.
- **Action** - `%LOCALAPPDATA%\tiger-backup.cmd`.

## Checking it worked

The directory is `0750 kristen:kristen`, so reading it takes `sudo`.

```bash
# the file landed
ssh tiger 'sudo ls /mnt/backups/kristen-data'

# tiger sees the heartbeat
ssh tiger 'curl -s "http://127.0.0.1:8428/api/v1/query?query=windows_backup_last_success_timestamp_seconds" | jq .'

# a snapshot picked it up
ssh tiger 'ls /mnt/backups/.zfs/snapshot/ | tail -1'

# pika has the second copy, after its daily syncoid
ssh pika 'sudo ls /tank/backups/kristen-data'

# and the offsite one, after pika's 06:00 push
aws s3 ls s3://ondy-archive-resolved-pug/backups/kristen-data/ --recursive | head
```

Then do a restore. Delete a file on the PC, let one run propagate the delete,
and pull it back out of `/mnt/backups/.zfs/snapshot/`. A backup nobody has
restored from is a guess.

## When it breaks

**`WindowsBackupStale` fires.** The PC being off for two days explains it.
So does a task that stopped, a changed SMB password, or a full pool. Check
Task Scheduler's History tab and `%LOCALAPPDATA%\tiger-backup.log`.

**Everything recopies every night.** `/FFT` is missing.

**Task Scheduler reports failure on a run that worked.** The `if errorlevel 8`
wrapper is missing or was rewritten to `if errorlevel 1`.

**Access denied on the share.** The credential belongs to a different user
than the task runs as. `cmdkey /list` as the task's account.

**`WindowsBackupNeverSucceeded` fires.** The directory has existed for a week
with no `_heartbeat` in it. Either step 5 never happened, or every run has
failed before the last line of the script.

**A cull on the PC deleted something wanted.** Recover from
`/mnt/backups/.zfs/snapshot/` on tiger, which keeps 31 dailies, reading it
with `sudo`. pika keeps the same data readonly for far longer, at daily 60,
monthly 36, yearly 15.

## Adding a second machine

Add an entry to `windowsBackupDirs`, a share and a POSIX account beside the
existing ones, and an `smb_<user>_password` secret. The secret needs two
lines of its own in `tiger/configuration.nix`: an entry in `sops.secrets`,
and a `seed` call in `samba-smbpasswd-seed`. The tmpfiles rules, the
heartbeat, the metric label and every alert follow from the list entry.
Then repeat the client steps with the new share name.
