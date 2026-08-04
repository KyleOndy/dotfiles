# Offsite holding pen for raw video during a project, from trex.
#
# Deliberately not the archive bucket. Raw footage is the one thing here that
# gets deliberately destroyed: once a project renders and the output is
# archived, every copy of the raws goes. That needs a credential that can
# delete, and a bucket boundary is much harder to get wrong than a
# prefix-scoped policy when the thing being deleted is irreversible.
#
# Standard-IA rather than Deep Archive. This data is read back mid-project at
# millisecond latency, and it lives for weeks rather than years, so Deep
# Archive's 180-day minimum would bill long after the footage is gone.
# Standard-IA's minimum is 30 days:
# https://docs.aws.amazon.com/AmazonS3/latest/userguide/storage-class-intro.html#sc-compare
#
# The storage class is set on the PUT, not by a transition rule, for the same
# reason as the archive bucket.
locals {
  video_scratch_bucket_name = "ondy-video-scratch"
}

resource "random_pet" "video_scratch_suffix" {
  length = 2
}

resource "aws_s3_bucket" "video_scratch" {
  bucket = "${local.video_scratch_bucket_name}-${random_pet.video_scratch_suffix.id}"
  tags = {
    # No comma. S3 tag values allow letters, digits, spaces and + - = . _ : / @
    Name = "Video project scratch: raw footage held offsite during a project"
  }
}

resource "aws_s3_bucket_versioning" "video_scratch" {
  bucket = aws_s3_bucket.video_scratch.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "video_scratch" {
  bucket                  = aws_s3_bucket.video_scratch.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "video_scratch" {
  bucket = aws_s3_bucket.video_scratch.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# No expiration on current versions. Purging raws is a decision made when a
# project ships, not on a clock that cannot know whether the edit is done.
# The 30 days below only governs how long a purge stays reversible.
resource "aws_s3_bucket_lifecycle_configuration" "video_scratch" {
  bucket = aws_s3_bucket.video_scratch.id

  rule {
    id     = "expire-noncurrent"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    expiration {
      expired_object_delete_marker = true
    }

    # Raw video multiparts are large enough that an abandoned upload is worth
    # real money, unlike the archive bucket's stills.
    abort_incomplete_multipart_upload {
      days_after_initiation = 3
    }
  }
}

output "video_scratch_bucket_name" {
  value = aws_s3_bucket.video_scratch.id
}

# DeleteObject, never DeleteObjectVersion. Same fleet-wide rule as the archive
# bucket: a purge writes delete markers, and only the lifecycle rule above
# ever destroys bytes.
resource "aws_iam_user" "video_scratch" {
  name = "svc.video-scratch"
}

resource "aws_iam_policy" "video_scratch" {
  name        = "VideoScratchS3Access"
  description = "Read, write and delete-marker access to the video scratch bucket for trex"
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
        Resource = aws_s3_bucket.video_scratch.arn
      },
      {
        Sid    = "ReadWriteDeleteObjects"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:PutObject",
          "s3:DeleteObject",
        ]
        Resource = "${aws_s3_bucket.video_scratch.arn}/*"
      },
    ]
  })
}

resource "aws_iam_user_policy_attachment" "video_scratch" {
  user       = aws_iam_user.video_scratch.name
  policy_arn = aws_iam_policy.video_scratch.arn
}
