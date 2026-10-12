# git-crypt key access

git-crypt's key directories are readable. That is a wider thing than it
sounds: the key file (`git-crypt/keys/default` in the git dir, one per
worktree, here 148 bytes) is the symmetric master key for every ciphertext
file in the repo, `tf/`'s `*.pem`, `*.key`, `*.secret`, `*.tfstate` and
`terraform.tfvars` included, past commits included. Whoever holds it
decrypts all of it.

The wrapper denies those directories by default because being allowed to
run the clean filter and being able to steal the key are one capability:
a process that can commit a filtered file is a process that can read the
key it encrypts with. Without this grant, in-session `git add` of a
filtered file fails loudly, which is the intended signal: committing
ciphertext-bearing files is a decision for the human, outside the
sandbox.

The deny keeps the key, not today's secrets. The session checkout omits
protected paths entirely (sparse checkout), so neither their plaintext nor
their ciphertext is present in this worktree; today's untracked secrets are
secret-guard's business, not the key's. What the key adds is every past
version, and every commit pushed after this session ends, since git-crypt
has no way to rotate it.

With this grant, treat the key as read. Anything that runs in this
session, and anything it writes anywhere, may already hold the master
key.
