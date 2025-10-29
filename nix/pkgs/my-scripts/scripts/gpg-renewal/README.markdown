# Key Renewal

## Quick and Dirty

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

## todo

- generate revocation keys
- generate printable backups
- Don't ask for password so many time
- Revisit my gpg.conf. That conf is no longer reccomened, I rember seeing on the website.
- Setup a reminder to not let keys expire
