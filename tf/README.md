# Terraform

Just some infrastructure code for resources outside of what I manage via Nix,
mostly within AWS.

- `dns.tf` / `iam.tf`: Route53 zones/records and the IAM users that update them.
- `photos-backup.tf`: the S3 Deep Archive bucket `backup-photos`
  (`nix/pkgs/backup-photos`) syncs the photo library to.

I know what you may be saying looking at files in this dir.

> WHAT! You've sourced `terraform.tf`? Don't you know thats bad?

Yes. I know the downfalls. I am the only developer, so concurrency does not
matter, and the file in encrypted at rest with [git-crypt], so the contents are
not public.

[git-crypt]: https://github.com/AGWA/git-crypt

## Run Locally

```
git-crypt unlock
for line in $(pass show aws.amazon.com/ondy-org/iam_users/admin | rg -e AWS_); do export "$line"; done
make
```
