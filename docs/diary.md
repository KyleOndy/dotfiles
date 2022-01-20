gpg: WARNING: unsafe permissions on homedir '/Users/kyle.ondy/.gnupg'

chown -R $(whoami) ~/.gnupg/
chmod 600 ~/.gnupg/\*
chmod 700 ~/.gnupg

---

var/empty

check env var, ex $GNUPGHOME
