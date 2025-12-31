# Key Renewal

## Unified Workflow (Recommended)

The `gpg-renew` script consolidates the entire renewal process into a single command.

### Usage

```bash
# 1. Mount your backup USB drive (or access existing mount)
udisksctl mount -b /dev/sdX1

# 2. Run renewal (auto-detects latest backup, prompts for passphrase once)
gpg-renew /mnt/data/GPG_Backups

# 3. Unmount USB
udisksctl unmount -b /dev/sdX1
```

### What it does

1. Auto-detects latest dated backup directory (e.g., `2025-09-18/`)
2. Creates secure temporary GNUPGHOME in tmpfs (`$XDG_RUNTIME_DIR`)
3. Imports secret keys from backup
4. Prompts for passphrase once and caches it
5. Extends key expiration by 100 days (master + all subkeys)
6. Exports keys to new dated backup directory (e.g., `2025-12-30/`)
7. Generates pre-generated revocation certificate (reason: key compromised)
8. Uploads public key to keyservers
9. Copies public key to `~/public.key`
10. Cleans up temporary GNUPGHOME automatically

### Directory structure

```text
/mnt/data/GPG_Backups/           # Argument to gpg-renew
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
send-to-yubi.sh /mnt/data/GPG_Backups/2025-12-30
```

---

## Legacy Manual Workflow

The original multi-script workflow is preserved below for reference.

### Quick and Dirty

```bash
# get backup keys onto this machine somehow
export g=<location of GPG backups>

. ./new-env.sh $g # note the script is sourced
# enter password
# edit the key if needed
./renew_gpg.sh $g
# enter password 3 more times
# create revocation, select 0, type
# > I have lost control of this key
# enter twic, y for yes
k=<EXPORTED value from last script>

./upload-key.sh
# backup keys to usb
```

---

## Completed Improvements

- ✅ Generate revocation keys automatically
- ✅ Single passphrase prompt (cached for all operations)
- ✅ Secure tmpfs GNUPGHOME (secrets never hit disk)
- ✅ Automatic cleanup of temporary directories
- ✅ Non-interactive key renewal
- ✅ Verification and checksums

## Future Enhancements

- Generate printable backups (paper wallet)
- Automated expiration reminder (systemd timer or cron)
- Revisit gpg.conf for modern best practices
