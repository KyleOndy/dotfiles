# S3 disaster-recovery target for the photo library. Versioned, no public
# access. Raws are excluded at sync time (see nix/pkgs/backup-photos and
# nix/pkgs/photos-fanout), not here: this bucket just holds whatever those
# scripts send it. Three prefixes, three different lifecycle treatments:
#
#   archive/     the authoritative, finished collection -> Deep Archive
#                after 30 days (this is the "durable" tier).
#   _projects/   in-flight work -- edited directly, so uploaded at
#                Standard-IA from the start (aws s3 sync
#                --storage-class STANDARD_IA in photos-fanout) rather than
#                transitioned into it, and deliberately kept OUT of Deep
#                Archive: Deep Archive's 180-day minimum-storage charge
#                plus re-upload-on-modtime-change would punish an actively
#                edited project.
#   _provisional/, helios.db   only reached by S3 opportunistically (see
#                backup-photos --s3), so still funneled into Deep Archive
#                after 30 days like before -- there's no routine push to
#                clean it up otherwise.
#
# IMPORTANT: these rules use explicit prefix filters rather than one
# catch-all `filter {}` rule. A catch-all would also match _projects/,
# silently double-transitioning Standard-IA objects into Deep Archive and
# defeating the point of keeping WIP out of it. Any new prefix added to the
# sync scripts needs its own rule here.
locals {
  photos_bucket_name        = "my-photo-backup-archive"
  photos_provisional_prefix = "_provisional/"
  photos_projects_prefix    = "_projects/"
  photos_archive_prefix     = "archive/"
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

    # Restores the effective behavior the old catch-all rule gave this
    # prefix: cheap deep-freeze for whatever an opportunistic travel push
    # left behind, made explicit now that the catch-all is scoped to
    # archive/ only.
    transition {
      days          = 30
      storage_class = "DEEP_ARCHIVE"
    }

    noncurrent_version_transition {
      noncurrent_days = 30
      storage_class   = "DEEP_ARCHIVE"
    }

    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  rule {
    id     = "ProjectsDataRule"
    status = "Enabled"

    filter {
      prefix = local.photos_projects_prefix
    }

    # No transition action: photos-fanout uploads directly with
    # --storage-class STANDARD_IA, so objects start there. (S3 also
    # requires >=30 days in Standard before transitioning to Standard-IA,
    # so a day-0 transition rule wouldn't validate anyway.) Deliberately
    # never transitions to Deep Archive -- see the header comment.
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

    transition {
      days          = 30
      storage_class = "DEEP_ARCHIVE"
    }

    noncurrent_version_transition {
      noncurrent_days = 30
      storage_class   = "DEEP_ARCHIVE"
    }

    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  rule {
    id     = "ArchiveDataRule"
    status = "Enabled"

    filter {
      prefix = local.photos_archive_prefix
    }

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

# Service account for tiger's photos-fanout systemd service (see
# nix/hosts/tiger/configuration.nix). Least privilege: read+write on
# objects in just this bucket, nothing else -- scoped narrower than the
# admin credentials used to run terraform itself.
resource "aws_iam_user" "photos_backup" {
  name = "svc.photos-backup"
}

resource "aws_iam_policy" "photos_backup" {
  name        = "PhotosBackupS3Access"
  description = "Read+write access to the photo backup bucket for tiger's photos-fanout service"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ListBucket"
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetBucketLocation",
        ]
        Resource = aws_s3_bucket.backup_bucket.arn
      },
      {
        Sid    = "ReadWriteObjects"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:DeleteObjectVersion",
        ]
        Resource = "${aws_s3_bucket.backup_bucket.arn}/*"
      },
    ]
  })
}

resource "aws_iam_user_policy_attachment" "photos_backup" {
  user       = aws_iam_user.photos_backup.name
  policy_arn = aws_iam_policy.photos_backup.arn
}
