# DNS and TLS for the app. Both are long-lived: a re-created hosted zone gets
# new name servers (breaking the registrar delegation), and certificates are
# slow to issue. Only the app's alias record lives in the ephemeral app stack.
#
# Delegation is manual: the registrar (Namecheap) must use the name servers in
# the name_servers output.

locals {
  app_fqdn = "${var.app_subdomain}.${var.domain_name}"
}

resource "aws_route53_zone" "main" {
  name    = var.domain_name
  comment = "Managed by Terraform (${var.project} bootstrap)"

  #checkov:skip=CKV2_AWS_38:DNSSEC needs a KMS key ($1/month) and a DS record at the registrar; future add-on
  #checkov:skip=CKV2_AWS_39:Query logging bills for CloudWatch Logs ingestion; not needed for a demo

  lifecycle {
    prevent_destroy = true
  }
}

# Only Amazon may issue certificates for this domain and its subdomains.
resource "aws_route53_record" "caa" {
  zone_id = aws_route53_zone.main.zone_id
  name    = var.domain_name
  type    = "CAA"
  ttl     = 3600
  records = [
    "0 issue \"amazon.com\"",
    "0 issuewild \"amazon.com\"",
  ]
}

# Covers the apex and any single-level subdomain, so new hostnames need no new
# certificate. ACM renews it automatically while the validation records exist.
resource "aws_acm_certificate" "main" {
  domain_name               = var.domain_name
  subject_alternative_names = ["*.${var.domain_name}"]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

# The apex and wildcard names share one validation record, hence allow_overwrite.
resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.main.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  }

  zone_id         = aws_route53_zone.main.zone_id
  name            = each.value.name
  type            = each.value.type
  ttl             = 300
  records         = [each.value.record]
  allow_overwrite = true
}

# Waits until ACM sees the validation record, which requires the registrar
# delegation to be in place.
resource "aws_acm_certificate_validation" "main" {
  certificate_arn         = aws_acm_certificate.main.arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]

  timeouts {
    create = "2h"
  }
}
