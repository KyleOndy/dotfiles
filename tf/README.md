# Terraform

Just some infrastructure code for resources outside of what I manage via Nix,
mostly within AWS.

I know what you may be saying looking at files in this dir.

> WHAT! You've sourced `terraform.tf`? Don't you know thats bad?

Yes. I know the downfalls. I am the only developer, so concurrency does not
matter, and the file in encrypted at rest with [git-crypt], so the contents are
not public.

[git-crypt]: https://github.com/AGWA/git-crypt
