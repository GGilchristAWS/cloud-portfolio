# Previous domain, kept only while DNS moves away from this account.
#
# mirkwood.xyz now belongs to a separate project, which hosts its own zone.
# This copy keeps answering (with its no-mail records) until the registrar
# points at the new zone and resolver caches expire. Delete this file then;
# the plan destroys the zone and its records.
#
# The records were renamed from their original addresses with
# `terraform state mv` (moved blocks can't be used: the new zone reuses them).

locals {
  mirkwood_domain  = "mirkwood.xyz"
  mirkwood_no_mail = toset([local.mirkwood_domain, "portfolio.${local.mirkwood_domain}"])
}

resource "aws_route53_zone" "mirkwood" {
  name    = local.mirkwood_domain
  comment = "Managed by Terraform (${var.project} bootstrap)"

  #checkov:skip=CKV2_AWS_38:Being removed; see note above
  #checkov:skip=CKV2_AWS_39:Being removed; see note above
}

resource "aws_route53_record" "mirkwood_caa" {
  zone_id = aws_route53_zone.mirkwood.zone_id
  name    = local.mirkwood_domain
  type    = "CAA"
  ttl     = 3600
  records = [
    "0 issue \"amazon.com\"",
    "0 issuewild \"amazon.com\"",
  ]
}

resource "aws_route53_record" "mirkwood_null_mx" {
  for_each = local.mirkwood_no_mail

  zone_id = aws_route53_zone.mirkwood.zone_id
  name    = each.value
  type    = "MX"
  ttl     = 3600
  records = ["0 ."]
}

resource "aws_route53_record" "mirkwood_spf" {
  for_each = local.mirkwood_no_mail

  zone_id = aws_route53_zone.mirkwood.zone_id
  name    = each.value
  type    = "TXT"
  ttl     = 3600
  records = ["v=spf1 -all"]
}

resource "aws_route53_record" "mirkwood_dkim_null" {
  zone_id = aws_route53_zone.mirkwood.zone_id
  name    = "*._domainkey.${local.mirkwood_domain}"
  type    = "TXT"
  ttl     = 3600
  records = ["v=DKIM1; p="]
}

resource "aws_route53_record" "mirkwood_dmarc" {
  zone_id = aws_route53_zone.mirkwood.zone_id
  name    = "_dmarc.${local.mirkwood_domain}"
  type    = "TXT"
  ttl     = 3600
  records = ["v=DMARC1; p=reject; sp=reject; adkim=s; aspf=s"]
}
