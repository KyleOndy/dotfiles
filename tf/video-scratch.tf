# Offsite holding pen for raw video during a project, from trex.
#
# Deliberately not the archive bucket. Raw footage is the one thing here that
# gets deliberately destroyed: once a project renders and the output is
# archived, every copy of the raws goes. That needs a credential that can
# delete, and a bucket boundary is much harder to get wrong than a
# prefix-scoped policy when the thing being deleted is irreversible.
#
# Two storage classes, split by what each half of a project is for.
#
# project/ is the edit: shot lists, stringouts, exports and the Resolve
# project library. Tens of MB, rewritten every session, and the half you
# would want back in a hurry. Standard-IA, 30-day minimum.
#
# footage/ is the camera negative. Hundreds of GB, written once when a card
# is dumped and never touched again. Deep Archive. It exists for "the house
# is gone" and nothing else, so a 12 to 48 hour restore is not a cost worth
# paying to avoid. At $0.00099/GB-month against Standard-IA's $0.0125, the
# whole 180-day minimum still costs less than a single month of IA: 222G is
# $1.32 committed either way, against $2.78 for one month of IA.
# https://aws.amazon.com/s3/pricing/
#
# Per-class minimum durations, which the lifecycle rules below are matched to:
# https://docs.aws.amazon.com/AmazonS3/latest/userguide/storage-class-intro.html#sc-compare
#
# The storage class is set on the PUT, not by a transition rule, for the same
# reason as the archive bucket.
locals {
  video_scratch_bucket_name = "ondy-video-scratch"

  # prefix -> noncurrent retention, in days. Each value is its prefix's
  # storage class minimum billing duration, which is the longest window that
  # is still free. Expiring sooner charges a prorated early-deletion fee and
  # buys nothing, the same trade archive-backup.tf records for its own 180.
  #
  # Set these from the storage class the pusher passes on the PUT
  # (nix/pkgs/backup-resolve-projects). Changing one without the other is how
  # this starts quietly costing money.
  video_scratch_windows = {
    "project/" = 30  # STANDARD_IA
    "footage/" = 180 # DEEP_ARCHIVE
  }
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

  dynamic "rule" {
    for_each = local.video_scratch_windows
    content {
      id     = "expire-noncurrent-${replace(rule.key, "/", "")}"
      status = "Enabled"

      filter {
        prefix = rule.key
      }

      noncurrent_version_expiration {
        noncurrent_days = rule.value
      }

      expiration {
        expired_object_delete_marker = true
      }

      # Raw video multiparts are large enough that an abandoned upload is
      # worth real money, unlike the archive bucket's stills.
      abort_incomplete_multipart_upload {
        days_after_initiation = 3
      }
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
