# Terraform

Infrastructure code for resources outside of what Nix manages, mostly AWS.

- `dns.tf` / `iam.tf`: Route53 zones/records and the IAM users that update them.
- `archive-backup.tf`: the tier 3 offsite bucket from
  `docs/backup-strategy.md`. pika is the only host that writes to it.
- `video-scratch.tf`: the holding bucket for raw video during a project,
  pushed from trex by `backup-resolve-projects --s3`.
- `state.tf`: the bucket this directory's state lives in, locked with S3
  lockfiles. Its comment has the bootstrap order for a fresh setup.

State is not in git. Reading it takes the AWS keys below, so a checkout of
this repo, or anything that can read one, never holds it. Git history keeps
the versions from before the move, as git-crypt ciphertext.

## Run Locally

```
make plan
make apply
```

The Makefile reads the AWS admin keys from
`pass show aws.amazon.com/ondy-org/iam_users/admin` on every run, so nothing
needs exporting first. Plain `make` runs only `terraform init`, the first rule
in the file, which is make's default goal ([make.texi, 4.4.1][make-goal]).

[make-goal]: https://git.savannah.gnu.org/cgit/make.git/tree/doc/make.texi?h=4.4.1
