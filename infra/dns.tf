# The hosted zone and certificate belong to the bootstrap stack so they
# survive teardown. Only the app's alias record lives here, because it must
# follow the load balancer's lifecycle. The deploy role may change only this
# record (see bootstrap/deploy_permissions.tf).

locals {
  app_fqdn = "${var.app_subdomain}.${var.domain_name}"
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
resource "aws_route53_record" "app" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = local.app_fqdn
  type    = "A"

  alias {
    name                   = aws_lb.this.dns_name
    zone_id                = aws_lb.this.zone_id
    evaluate_target_health = true
  }
}
