# Key Renewal

## Unified Workflow (Recommended)

The `gpg-renew` script consolidates the entire renewal process into a single command.

### Usage

```bash
# 1. Mount your backup USB drive on Linux (or use an existing mount)
udisksctl mount -b /dev/sdX1

# 2. Run renewal (auto-detects latest backup, prompts for passphrase once)
gpg-renew <mountpoint>/GPG_Backups

# 3. Unmount USB
udisksctl unmount -b /dev/sdX1
```

`udisksctl mount` prints the mountpoint it chose ([udisksctl(1), Debian bookworm][udisksctl]). my-scripts installs every script in this directory flat onto PATH, so each one runs by name from anywhere.

### What it does

1. Auto-detects latest dated backup directory (e.g., `2025-09-18/`)
2. Creates a temporary GNUPGHOME under `$XDG_RUNTIME_DIR`, else `/dev/shm`, else `/tmp`. The macs have neither of the first two (nothing here sets `XDG_RUNTIME_DIR` on darwin), so there it lands in `/tmp`, on disk.
3. Imports secret keys from backup
4. Prompts for passphrase once and caches it
5. Sets key expiration to 100 days from today (master + all subkeys), per `--quick-set-expire` ([gpg.texi, GnuPG 2.4.5][gpg-texi])
6. Exports keys to new dated backup directory (e.g., `2025-12-30/`)
7. Generates pre-generated revocation certificate (reason: key compromised)
8. Uploads public key to keyservers
9. Copies public key to `~/public.key`
10. Removes the temporary GNUPGHOME on exit, when it sits under `/run/user`, `/dev/shm` or `/tmp`

### Directory structure

```text
<mountpoint>/GPG_Backups/        # Argument to gpg-renew
├── 2025-09-18/                  # Previous backup (auto-detected as latest)
│   ├── public.key
│   ├── revocation.key
│   ├── secret.key
│   └── secret_sub.key
└── 2025-12-30/                  # New backup (created by gpg-renew)
    ├── public.key
    ├── revocation.key
    ├── secret.key
    ├── secret_sub.key
    └── SHA256SUMS               # Checksums for verification
```

### YubiKey Setup (Optional)

Only needed when setting up a new YubiKey:

```bash
send-to-yubi.sh <mountpoint>/GPG_Backups/2025-12-30
```

It imports `secret.key` and `secret_sub.key` into a fresh `mktemp -d` directory, copies `gpg-agent.conf` in from `$GNUPGHOME`, and never removes that directory. Delete it once the keys are on the card. It also runs `pkill gpg-agent`, which stops every agent you have running.

---

## Legacy Manual Workflow

The original multi-script workflow is preserved below for reference.

### Quick and Dirty

```bash
# get backup keys onto this machine somehow
export g=<location of GPG backups>

. new-env.sh $g # note the script is sourced
# enter password
# edit the key if needed
renew-gpg.sh # takes no arguments, exports to $GNUPGHOME/<date>
# enter password 3 more times
# create revocation, select 0, type
# > I have lost control of this key
# enter twice, y for yes
k=<EXPORTED value from last script>

upload-key.sh
# backup $k to usb
```

`new-env.sh` only works sourced. Run by name, it sets `GNUPGHOME` in a child process that exits straight away. Its usage check calls `exit 1`, which closes the shell that sourced it, so always pass the directory.

`export-keys <dir>` exports the keyring in the current `$GNUPGHOME` into a new `<dir>/<date>/`, which must not exist yet. It writes `public.key`, `secret.key`, `secret-subkeys.key` and `revocation`, the last with reason 0 and the text "I've lost control of this key". The subkey and revocation file names differ from the ones `gpg-renew` writes.

---

## Completed Improvements

- Generate revocation keys automatically
- Single passphrase prompt (cached for all operations)
- Temporary GNUPGHOME in tmpfs where the host has one (on disk in `/tmp` on the macs)
- Automatic cleanup of `gpg-renew`'s temporary GNUPGHOME
- Non-interactive key renewal
- Verification and checksums

## Future Enhancements

- Generate printable backups (paper wallet)
- Automated expiration reminder (systemd timer or cron)
- Revisit gpg.conf for modern best practices

[udisksctl]: https://manpages.debian.org/bookworm/udisks2/udisksctl.1.en.html
[gpg-texi]: https://github.com/gpg/gnupg/blob/gnupg-2.4.5/doc/gpg.texi
