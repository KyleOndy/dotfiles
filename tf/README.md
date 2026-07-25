# Terraform

Infrastructure code for resources outside of what Nix manages, mostly AWS.

- `dns.tf` / `iam.tf`: Route53 zones/records and the IAM users that update them.
- `photos-backup.tf`: the S3 Deep Archive bucket `backup-photos`
  (`nix/pkgs/backup-photos`) syncs the photo library to.

`terraform.tfstate` is committed. One developer, so there is no concurrency
problem, and `.gitattributes` runs `tf/*.tfstate` through [git-crypt], so the
contents are not public.

[git-crypt]: https://github.com/AGWA/git-crypt

## Run Locally

```
git-crypt unlock
for line in $(pass show aws.amazon.com/ondy-org/iam_users/admin | rg -e AWS_); do export "$line"; done
make
```
