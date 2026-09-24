# Terraform

Infrastructure code for resources outside of what Nix manages, mostly AWS.

- `dns.tf` / `iam.tf`: Route53 zones/records and the IAM users that update them.
- `photos-backup.tf`: the photo disaster-recovery bucket. tiger's
  `photos-fanout` pushes `archive/` and `helios.db` to it, and
  `backup-photos --s3` (`nix/pkgs/backup-photos`) pushes `_provisional/`
  opportunistically. Lifecycle rules move all of it to Deep Archive after 30
  days.
- `archive-backup.tf`: the tier 3 offsite bucket from
  `docs/backup-strategy.md`. pika is the only host that writes to it.
- `video-scratch.tf`: the holding bucket for raw video during a project,
  pushed from trex by `backup-resolve-projects --s3`.

`terraform.tfstate` is committed. One developer, so there is no concurrency
problem, and `.gitattributes` runs `tf/*.tfstate` through [git-crypt], so the
contents are not public.

[git-crypt]: https://github.com/AGWA/git-crypt

## Run Locally

```
git-crypt unlock
make plan
make apply
```

The Makefile reads the AWS admin keys from
`pass show aws.amazon.com/ondy-org/iam_users/admin` on every run, so nothing
needs exporting first. Plain `make` runs only `terraform init`, the first rule
in the file, which is make's default goal ([make.texi, 4.4.1][make-goal]).

[make-goal]: https://git.savannah.gnu.org/cgit/make.git/tree/doc/make.texi?h=4.4.1
