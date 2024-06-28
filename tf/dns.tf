## ondy.org

resource "aws_route53_zone" "ondy_org" {
  name = "ondy.org"
}

resource "aws_route53_record" "ondy_org_apps_star_cname" {
  zone_id = aws_route53_zone.ondy_org.zone_id
  name    = "*.apps.ondy.org"
  type    = "CNAME"
  ttl     = "300"
  records = ["home.1ella.com"]
}

resource "aws_route53_record" "ondy_org_top_level_app" {
  for_each = toset(var.ondy_org_top_level_apps)


  zone_id = aws_route53_zone.ondy_org.zone_id
  name    = each.value
  type    = "CNAME"
  ttl     = "300"
  records = ["home.1ella.com"]
}

resource "aws_route53_record" "org_ondy_mx" {
  zone_id = aws_route53_zone.ondy_org.zone_id
  name    = "ondy.org"
  type    = "MX"
  ttl     = "3600"
  records = [
    "10 london.mxroute.com",
    "20 london-relay.mxroute.com",
  ]
}

resource "aws_route53_record" "org_ondy_txt" {
  zone_id = aws_route53_zone.ondy_org.zone_id
  name    = "ondy.org"
  type    = "TXT"
  ttl     = "3600"
  records = ["v=spf1 include:mxroute.com -all"]
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
