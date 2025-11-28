locals {
  cheetah_dns = ["ns100099.ip-147-135-1.us"]
  wolf_dns = ["ns568215.ip-51-79-99.net"]
}

## ondy.org
resource "aws_route53_zone" "ondy_org" {
  name = "ondy.org"
}

resource "aws_route53_record" "ondy_org_apex" {
  zone_id = aws_route53_zone.ondy_org.zone_id
  name    = "ondy.org"
  type    = "A"
  ttl     = "300"
  records = ["147.135.1.147"]
}

resource "aws_route53_record" "ondy_org_apps_subdomains" {
  for_each = toset(var.ondy_org_apps_subdomains)

  zone_id = aws_route53_zone.ondy_org.zone_id
  name    = "${each.value}.apps.ondy.org"
  type    = "CNAME"
  ttl     = "300"
  records = local.cheetah_dns
}

resource "aws_route53_record" "ondy_org_top_level_app" {
  for_each = toset(var.ondy_org_top_level_apps)

  zone_id = aws_route53_zone.ondy_org.zone_id
  name    = "${each.value}.ondy.org"
  type    = "CNAME"
  ttl     = "300"
  records = local.cheetah_dns
}

resource "aws_route53_record" "ondy_org_mx" {
  zone_id = aws_route53_zone.ondy_org.zone_id
  name    = "ondy.org"
  type    = "MX"
  ttl     = "3600"
  records = [
    "10 london.mxroute.com",
    "20 london-relay.mxroute.com",
  ]
}

resource "aws_route53_record" "ondy_org_txt" {
  zone_id = aws_route53_zone.ondy_org.zone_id
  name    = "ondy.org"
  type    = "TXT"
  ttl     = "3600"
  records = ["v=spf1 include:mxroute.com -all"]
}

resource "aws_route53_record" "ondy_org_txt_atproto" {
  zone_id = aws_route53_zone.ondy_org.zone_id
  name    = "_atproto.ondy.org"
  type    = "TXT"
  ttl     = "86400"
  records = ["did=did:plc:2qod5zgss7zqpbockr7syiqg"]
}

output "ondy_org_nameservers" {
  value = aws_route53_zone.ondy_org.name_servers
}

## ondy.me

resource "aws_route53_zone" "ondy_me" {
  name = "ondy.me"
}

resource "aws_route53_record" "ondy_me_mx" {
  zone_id = aws_route53_zone.ondy_me.zone_id
  name    = "ondy.me"
  type    = "MX"
  ttl     = "3600"
  records = [
    "10 london.mxroute.com",
    "20 london-relay.mxroute.com",
  ]
}

resource "aws_route53_record" "ondy_me_txt" {
  zone_id = aws_route53_zone.ondy_me.zone_id
  name    = "ondy.me"
  type    = "TXT"
  ttl     = "3600"
  records = ["v=spf1 include:mxroute.com -all"]
}

output "ondy_me_nameservers" {
  value = aws_route53_zone.ondy_me.name_servers
}

## kyleondy.com
resource "aws_route53_zone" "kyleondy_com" {
  name = "kyleondy.com"
}

resource "aws_route53_record" "kyleondy_com_apex" {
  zone_id = aws_route53_zone.kyleondy_com.zone_id
  name    = "kyleondy.com"
  type    = "A"
  ttl     = "300"
  records = ["147.135.1.147"]
}

resource "aws_route53_record" "kyleondy_com_www" {
  zone_id = aws_route53_zone.kyleondy_com.zone_id
  name    = "www.kyleondy.com"
  type    = "CNAME"
  ttl     = "300"
  records = local.cheetah_dns
}
