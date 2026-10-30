# The hosted zone, certificates and the public names (demo.<domain> and
# grafana.<domain>, both CloudFront) belong to the bootstrap stack so they
# survive teardown (bootstrap/edge.tf). This stack owns only origin.<domain>:
# the alias CloudFront follows to this session's load balancer. The deploy
# role may change only this record (see bootstrap/deploy_permissions.tf).

locals {
  # An empty subdomain serves the app at the zone apex.
  app_fqdn    = var.app_subdomain == "" ? var.domain_name : "${var.app_subdomain}.${var.domain_name}"
  origin_fqdn = "origin.${var.domain_name}"
}

data "aws_route53_zone" "main" {
  name         = var.domain_name
  private_zone = false
}

data "aws_acm_certificate" "main" {
  domain      = var.domain_name
  statuses    = ["ISSUED"]
  types       = ["AMAZON_ISSUED"]
  most_recent = true
}

# Alias records are free to query and track the ALB's changing IP addresses.
resource "aws_route53_record" "origin" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = local.origin_fqdn
  type    = "A"

  alias {
    name                   = aws_lb.this.dns_name
    zone_id                = aws_lb.this.zone_id
    evaluate_target_health = true
  }
}
