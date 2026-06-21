locals {
  # Generate IAM policy dynamically using actual zone IDs
  acme_policy_json = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = ""
        Effect   = "Allow"
        Action   = "route53:GetChange"
        Resource = "arn:aws:route53:::change/*"
      },
      {
        Sid      = ""
        Effect   = "Allow"
        Action   = "route53:ListHostedZonesByName"
        Resource = "*"
      },
      {
        Sid    = ""
        Effect = "Allow"
        Action = "route53:ListResourceRecordSets"
        Resource = [
          "arn:aws:route53:::hostedzone/${aws_route53_zone.kyleondy_com.zone_id}",
          "arn:aws:route53:::hostedzone/${aws_route53_zone.ondy_org.zone_id}",
          "arn:aws:route53:::hostedzone/${aws_route53_zone.ondy_me.zone_id}",
        ]
      },
      {
        Sid    = ""
        Effect = "Allow"
        Action = "route53:ChangeResourceRecordSets"
        Resource = [
          "arn:aws:route53:::hostedzone/${aws_route53_zone.kyleondy_com.zone_id}",
          "arn:aws:route53:::hostedzone/${aws_route53_zone.ondy_org.zone_id}",
          "arn:aws:route53:::hostedzone/${aws_route53_zone.ondy_me.zone_id}",
        ]
        Condition = {
          "ForAllValues:StringEquals" = {
            "route53:ChangeResourceRecordSetsRecordTypes" = "TXT"
          }
        }
      }
    ]
  })
}

# Import existing IAM user
resource "aws_iam_user" "acme" {
  name = "svc.acme"
}

# Create managed policy from dynamically generated policy
resource "aws_iam_policy" "acme_route53" {
  name        = "AcmeRoute53Access"
  description = "Allows ACME challenges via Route53 TXT record modifications"
  policy      = local.acme_policy_json
}

# Attach managed policy to user
resource "aws_iam_user_policy_attachment" "acme_route53" {
  user       = aws_iam_user.acme.name
  policy_arn = aws_iam_policy.acme_route53.arn
}

# DDNS updater on tiger. Writes the live home WAN IP into the two bare apex A
# records (ondy.org, kyleondy.com), which can't follow the home IP any other way.
# Least privilege: A-record ChangeResourceRecordSets on just those two names.
resource "aws_iam_user" "ddns" {
  name = "svc.ddns"
}

resource "aws_iam_policy" "ddns_route53" {
  name        = "DdnsRoute53Access"
  description = "Update apex A records (ondy.org, kyleondy.com) with the home WAN IP"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = ""
        Effect = "Allow"
        Action = "route53:ChangeResourceRecordSets"
        Resource = [
          "arn:aws:route53:::hostedzone/${aws_route53_zone.ondy_org.zone_id}",
          "arn:aws:route53:::hostedzone/${aws_route53_zone.kyleondy_com.zone_id}",
        ]
        Condition = {
          "ForAllValues:StringEquals" = {
            "route53:ChangeResourceRecordSetsRecordTypes" = "A"
            "route53:ChangeResourceRecordSetsNormalizedRecordNames" = [
              "ondy.org",
              "kyleondy.com",
            ]
          }
        }
      }
    ]
  })
}

resource "aws_iam_user_policy_attachment" "ddns_route53" {
  user       = aws_iam_user.ddns.name
  policy_arn = aws_iam_policy.ddns_route53.arn
}
