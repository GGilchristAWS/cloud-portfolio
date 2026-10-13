# This domain neither sends nor receives email. These records say so
# explicitly, so receivers reject mail forging a sender in this zone and
# senders fail fast instead of retrying. Relax them before adding a mail
# provider (e.g. SES): MX, SPF include, DKIM keys, then DMARC.
#
# Only one TXT record set may exist per name: future TXT values at these
# names (e.g. site verification) must be added to the records lists below.

locals {
  # Names with address records need their own null MX and SPF; neither is
  # inherited by subdomains.
  no_mail_names = toset([var.domain_name, local.app_fqdn])
}

# Null MX (RFC 7505): accepts no mail. Without it, senders fall back to the
# name's A record (implicit MX) and retry for days.
resource "aws_route53_record" "null_mx" {
  for_each = local.no_mail_names

  zone_id = aws_route53_zone.main.zone_id
  name    = each.value
  type    = "MX"
  ttl     = 3600
  records = ["0 ."]
}

# SPF: no host may send mail for these names.
resource "aws_route53_record" "spf" {
  for_each = local.no_mail_names

  zone_id = aws_route53_zone.main.zone_id
  name    = each.value
  type    = "TXT"
  ttl     = 3600
  records = ["v=spf1 -all"]
}

# DKIM: an empty (revoked) key for every selector, so any signature claiming
# this domain fails verification.
resource "aws_route53_record" "dkim_null" {
  zone_id = aws_route53_zone.main.zone_id
  name    = "*._domainkey.${var.domain_name}"
  type    = "TXT"
  ttl     = 3600
  records = ["v=DKIM1; p="]
}

# DMARC: reject mail failing SPF/DKIM alignment for the domain and, via sp=,
# all subdomains. No rua reporting address: there is no mailbox to receive
# aggregate reports.
resource "aws_route53_record" "dmarc" {
  zone_id = aws_route53_zone.main.zone_id
  name    = "_dmarc.${var.domain_name}"
  type    = "TXT"
  ttl     = 3600
  records = ["v=DMARC1; p=reject; sp=reject; adkim=s; aspf=s"]
}
