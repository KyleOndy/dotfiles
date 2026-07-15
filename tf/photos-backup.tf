# S3 disaster-recovery target for the photo library (~/photos on dino).
# Deep Archive storage, versioned, no public access. Raws are excluded at
# sync time (see nix/pkgs/backup-photos), not here: this bucket just holds
# whatever backup-photos-to-dr sends it.
#
# _provisional/ is the import/cull inbox, not scratch: files can sit there
# for a long time before a cull session gets to them, so it gets the same
# archiving as everything else. It differs only in how long a deleted
# version is kept around (90 days, vs. 2 years for the rest) since culls are
# expected and don't need the long regret window main photos get.
locals {
  photos_bucket_name        = "my-photo-backup-archive"
  photos_provisional_prefix = "_provisional/"
}

resource "random_pet" "suffix" {
  length = 2
}

resource "aws_s3_bucket" "backup_bucket" {
  bucket = "${local.photos_bucket_name}-${random_pet.suffix.id}"
  tags = {
    Name = "Photo Backup Bucket"
  }
}

resource "aws_s3_bucket_versioning" "versioning" {
  bucket = aws_s3_bucket.backup_bucket.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "public_access" {
  bucket                  = aws_s3_bucket.backup_bucket.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "encryption" {
  bucket = aws_s3_bucket.backup_bucket.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "backup_lifecycle" {
  bucket = aws_s3_bucket.backup_bucket.id

  rule {
    id     = "ProvisionalDataRule"
    status = "Enabled"

    filter {
      prefix = local.photos_provisional_prefix
    }

    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  rule {
    id     = "DatabaseFileRule"
    status = "Enabled"

    filter {
      prefix = "helios.db"
    }

    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  rule {
    id     = "DefaultToDeepArchiveRule"
    status = "Enabled"
    filter {}

    transition {
      days          = 30
      storage_class = "DEEP_ARCHIVE"
    }

    noncurrent_version_transition {
      noncurrent_days = 30
      storage_class   = "DEEP_ARCHIVE"
    }

    noncurrent_version_expiration {
      noncurrent_days = 730
    }

    expiration {
      expired_object_delete_marker = true
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

output "photos_backup_bucket_name" {
  value = aws_s3_bucket.backup_bucket.id
}
