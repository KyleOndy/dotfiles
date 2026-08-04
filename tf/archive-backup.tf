# Tier 3 of docs/backup-strategy.md: the offsite copy that answers "the house
# is gone", not "I deleted a file last week". pika answers the second, holds
# the snapshot history, and is the only host that writes here.
#
# Two prefixes, one bucket. photos/ and backups/ have identical policy: never
# machine-deleted, restored together, same credential, same storage class.
# Two buckets with identical policy is two things to drift.
#
# No transition rules anywhere below. The pusher sets DEEP_ARCHIVE on the PUT
# itself, which avoids a transition request per object and sidesteps the
# September 2024 default that refuses to transition objects under 128 KB:
# https://docs.aws.amazon.com/AmazonS3/latest/userguide/lifecycle-transition-general-considerations.html#lifecycle-configuration-constraints
# Under a transition-based rule every sidecar and small JPEG would sit in
# Standard forever at 23x the price, and nothing would report it.
locals {
  archive_bucket_name = "ondy-archive"
  archive_prefixes    = ["photos/", "backups/"]
}

resource "random_pet" "archive_suffix" {
  length = 2
}

resource "aws_s3_bucket" "archive" {
  bucket = "${local.archive_bucket_name}-${random_pet.archive_suffix.id}"
  tags = {
    Name = "Offsite archive: photos and documents"
  }
}

resource "aws_s3_bucket_versioning" "archive" {
  bucket = aws_s3_bucket.archive.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "archive" {
  bucket                  = aws_s3_bucket.archive.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# SSE-S3 rather than client-side or SSE-C. A client-side key is one more thing
# that has to survive the event this bucket exists for, and a key that must
# survive is the same problem twice. AWS-managed means account access alone is
# enough to read the archive back.
resource "aws_s3_bucket_server_side_encryption_configuration" "archive" {
  bucket = aws_s3_bucket.archive.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# 180 days, not 90. Deep Archive bills a 180-day minimum and charges a
# prorated early-deletion fee for anything removed sooner, so expiring at 90
# costs exactly the same and buys half the undelete window:
# https://docs.aws.amazon.com/AmazonS3/latest/userguide/lifecycle-transition-general-considerations.html#glacier-pricing-considerations
resource "aws_s3_bucket_lifecycle_configuration" "archive" {
  bucket = aws_s3_bucket.archive.id

  dynamic "rule" {
    for_each = local.archive_prefixes
    content {
      id     = "expire-noncurrent-${replace(rule.value, "/", "")}"
      status = "Enabled"

      filter {
        prefix = rule.value
      }

      noncurrent_version_expiration {
        noncurrent_days = 180
      }

      expiration {
        expired_object_delete_marker = true
      }

      abort_incomplete_multipart_upload {
        days_after_initiation = 7
      }
    }
  }
}

output "archive_bucket_name" {
  value = aws_s3_bucket.archive.id
}

# Two credentials, split on one verb.
#
# A simple DELETE against a versioned bucket cannot destroy anything; it
# inserts a delete marker and the data survives as a noncurrent version.
# Permanent removal requires DELETE with a versionId, gated by
# s3:DeleteObjectVersion:
# https://docs.aws.amazon.com/AmazonS3/latest/userguide/DeletingObjectVersions.html#delete-request-use-cases
#
# So no host in the fleet gets s3:DeleteObjectVersion. Permanent removal is
# exclusively the lifecycle rule above, running as S3 rather than as anything
# holding a key. A fully compromised pika can write 157k delete markers and
# destroy zero bytes.
resource "aws_iam_user" "archive_push" {
  name = "svc.archive-push"
}

resource "aws_iam_policy" "archive_push" {
  name        = "ArchivePushS3Access"
  description = "Put-only access to the offsite archive bucket for pika's daily sync"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ListBucket"
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:ListBucketVersions",
          "s3:GetBucketLocation",
        ]
        Resource = aws_s3_bucket.archive.arn
      },
      {
        # GetObject is here for the restore drill and for `aws s3 sync` to
        # compare, not because the push needs to read anything back.
        Sid    = "ReadWriteObjects"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:PutObject",
        ]
        Resource = "${aws_s3_bucket.archive.arn}/*"
      },
    ]
  })
}

resource "aws_iam_user_policy_attachment" "archive_push" {
  user       = aws_iam_user.archive_push.name
  policy_arn = aws_iam_policy.archive_push.arn
}

resource "aws_iam_user" "archive_prune" {
  name = "svc.archive-prune"
}

resource "aws_iam_policy" "archive_prune" {
  name        = "ArchivePruneS3Access"
  description = "Delete-marker-only access for pika's weekly orphan prune"
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
        Resource = aws_s3_bucket.archive.arn
      },
      {
        Sid      = "DeleteMarkersOnly"
        Effect   = "Allow"
        Action   = ["s3:DeleteObject"]
        Resource = "${aws_s3_bucket.archive.arn}/*"
      },
    ]
  })
}

resource "aws_iam_user_policy_attachment" "archive_prune" {
  user       = aws_iam_user.archive_prune.name
  policy_arn = aws_iam_policy.archive_prune.arn
}
