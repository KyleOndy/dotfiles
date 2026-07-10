locals {
  wolf_dns  = ["ns568215.ip-51-79-99.net"]
  wolf_ip   = ["51.79.99.201"]
  tiger_dns = ["tiger.infra.ondy.org"]
}

## ondy.org
resource "aws_route53_zone" "ondy_org" {
  name = "ondy.org"
}

resource "aws_route53_record" "ondy_org_apex" {
  zone_id = aws_route53_zone.ondy_org.zone_id
  name    = "ondy.org"
  type    = "A"
  ttl     = 300

  # Apex can't CNAME, and Route53 won't alias an apex A into the
  # tiger.infra -> home.1ella.com CNAME chain. So the ddns-route53 updater on
  # tiger pushes the live home WAN IP straight into this record. Terraform owns
  # that the record exists; the updater owns its value (hence ignore_changes).
  # Seeded to the current home IP so it's correct from the first apply. Caddy on
  # tiger then 301s ondy.org -> www.kyleondy.com.
  records = ["69.127.153.108"]

  lifecycle {
    ignore_changes = [records]
  }
}


resource "aws_route53_record" "ondy_org_tiger_apps" {
  for_each = toset(var.tiger_apps_subdomains)

  zone_id = aws_route53_zone.ondy_org.zone_id
  name    = "${each.value}.apps.ondy.org"
  type    = "CNAME"
  ttl     = "300"
  records = local.tiger_dns
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

resource "aws_route53_record" "ondy_org_photos" {
  zone_id = aws_route53_zone.ondy_org.zone_id
  name    = "photos.ondy.org"
  type    = "CNAME"
  ttl     = "300"
  records = local.tiger_dns
}

# Public compliance/landing site for the Cogsworth SMS service, served as a
# static site by Caddy on tiger. Distinct from cogsworth.infra.ondy.org (the Pi).
resource "aws_route53_record" "ondy_org_cogsworth" {
  zone_id = aws_route53_zone.ondy_org.zone_id
  name    = "cogsworth.ondy.org"
  type    = "CNAME"
  ttl     = "300"
  records = local.tiger_dns
}


resource "aws_route53_record" "ondy_org_infra_tiger" {
  zone_id = aws_route53_zone.ondy_org.zone_id
  name    = "tiger.infra.ondy.org"
  type    = "CNAME"
  ttl     = "300"
  # home.1ella.com is kept current by the UniFi console's DDNS updater
  records = ["home.1ella.com"]
}

resource "aws_route53_record" "ondy_org_infra_tiger_wildcard" {
  zone_id = aws_route53_zone.ondy_org.zone_id
  name    = "*.tiger.infra.ondy.org"
  type    = "CNAME"
  ttl     = "300"
  records = ["tiger.infra.ondy.org"]
}

resource "aws_route53_record" "ondy_org_infra_cogsworth" {
  zone_id = aws_route53_zone.ondy_org.zone_id
  name    = "cogsworth.infra.ondy.org"
  type    = "A"
  ttl     = "300"
  records = ["10.24.89.7"]
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
  ttl     = 300

  # Apex can't CNAME, and Route53 won't alias an apex A into the www -> tiger.infra
  # -> home.1ella.com CNAME chain. The ddns-route53 updater on tiger keeps this
  # pointed at the live home WAN IP. Terraform owns existence; the updater owns the
  # value (ignore_changes). Caddy on tiger 301s the apex -> www.
  records = ["69.127.153.108"]

  lifecycle {
    ignore_changes = [records]
  }
}

resource "aws_route53_record" "kyleondy_com_www" {
  zone_id = aws_route53_zone.kyleondy_com.zone_id
  name    = "www.kyleondy.com"
  type    = "CNAME"
  ttl     = "300"
  records = local.tiger_dns
}
