# Key Renewal

## Quick and Dirty

```bash
# get backup keys onto this machine somehow
export g=<location of GPG backups>

. ./new-env.sh $g # note the script is sourced
# edit the key if needed
./renew_gpg.sh $g
k=<EXPORTED value from last script>

# just using the new public key on a computer without touching the yubikey
# seemed to work. Is this expected?

# for each yubikey
./send_to_yubi.sh $k

./upload-key.sh

<generate public key>
<backup keys>

## after key looks good, in fresh normal term
./upload-key.sh
```

## todo

- generate revocation keys
- generate printable backups
- Don't ask for password so many time
- Revisit my gpg.conf. That conf is no longer reccomened, I rember seeing on the website.
- Setup a reminder to not let keys expire
