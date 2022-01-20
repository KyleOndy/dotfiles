gpg: WARNING: unsafe permissions on homedir '/Users/kyle.ondy/.gnupg'

chown -R $(whoami) ~/.gnupg/
chmod 600 ~/.gnupg/\*
chmod 700 ~/.gnupg

---

var/empty

check env var, ex $GNUPGHOME

---

Uh oh, messed up your nix-store? Maybe tried to `rm -rf` some config file that
was actually in the nix store? Try running the following to save the day.

```
nix-store --verify --check-contents --repair
```
