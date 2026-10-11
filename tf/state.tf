# Remote state for this directory, so terraform.tfstate lives here rather
# than in git.
#
# The bucket is managed by the config whose state it holds, so it has to
# exist before the backend can name it: a fresh setup applies this file with
# a local backend first, then runs `terraform init -migrate-state`. Losing
# the bucket loses the state, hence prevent_destroy, and versioning keeps a
# bad write one noncurrent version from undone.
#
# Not the archive bucket: its Object Lock retention would keep every state
# write for good, and nothing Terraform reads on every plan belongs in
# DEEP_ARCHIVE.
locals {
  tfstate_bucket_name = "ondy-tfstate"
}

resource "random_pet" "tfstate_suffix" {
  length = 2
}

resource "aws_s3_bucket" "tfstate" {
  bucket = "${local.tfstate_bucket_name}-${random_pet.tfstate_suffix.id}"
  tags = {
    Name = "Terraform state for the dotfiles tf directory"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

output "tfstate_bucket_name" {
  value = aws_s3_bucket.tfstate.id
}
