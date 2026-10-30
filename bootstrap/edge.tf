# CloudFront in front of the on-demand demo and its Grafana. The distributions
# are permanent, so demo.<domain> and grafana.<domain> always resolve to
# CloudFront, never to a load balancer's address. (Before, a browser holding a
# cached answer from an earlier session could reach the old ALB's IP address
# after AWS had given it to another customer, and got their certificate.)
#
#   https://demo.<domain>    -+-> CloudFront --> origin.<domain>: this session's ALB
#   https://grafana.<domain> -+               \-> "demo is off" page (site bucket)
#
# Each session's app stack (infra/dns.tf) points origin.<domain> at its new
# ALB; CloudFront's resolvers honor the 60-second TTL. The viewer's Host header
# is forwarded, so the ALB still routes grafana.<domain> to Grafana. While the
# demo is down the origin doesn't resolve, and visitors get the "demo is off"
# page instead of an error.
#
# The ALB admits only CloudFront's address ranges and requests carrying the
# X-Origin-Verify header below, so nothing can reach it around the blocklist
# or WAF, not even another CloudFront distribution pointed at the origin.
#
# Unexpected traffic (README, "Unexpected traffic"):
#   blocklist - a CloudFront Function refuses IPs listed in a key value store;
#               scripts/edge.sh blocks and unblocks in seconds. About $0.
#   logs      - access logs of all three distributions in CloudWatch Logs, for
#               scripts/edge.sh top (busiest IPs). Cents a month.
#   alarm     - emails when request volume across them is unusually high.
#   WAF       - var.waf_enabled: a per-IP rate limit and AWS's IP reputation
#               list. Off until abuse is seen; about $7/month while on.

locals {
  origin_fqdn  = "origin.${var.domain_name}"
  grafana_fqdn = "grafana.${var.domain_name}"
  offline_page = "/demo-offline.html" # written by app/scripts/build_site.py

  edge_hosts = {
    demo    = local.app_fqdn
    grafana = local.grafana_fqdn
  }

  # Every distribution, for logs and the traffic alarm.
  distributions = merge(
    { site = aws_cloudfront_distribution.site },
    aws_cloudfront_distribution.edge,
  )

  web_acl_arn = var.waf_enabled ? aws_wafv2_web_acl.edge[0].arn : null
}

# --- Certificate -------------------------------------------------------------

# CloudFront takes certificates only from us-east-1, so dns.tf's regional
# wildcard can't be reused. This one names exactly the two hosts.
resource "aws_acm_certificate" "edge" {
  region                    = "us-east-1"
  domain_name               = local.app_fqdn
  subject_alternative_names = [local.grafana_fqdn]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "edge_cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.edge.domain_validation_options : dvo.domain_name => {
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

resource "aws_acm_certificate_validation" "edge" {
  region                  = "us-east-1"
  certificate_arn         = aws_acm_certificate.edge.arn
  validation_record_fqdns = [for record in aws_route53_record.edge_cert_validation : record.fqdn]
}

# --- Origin lock ---------------------------------------------------------------

# Proof that a request came through these distributions; the app stack's ALB
# forwards only requests carrying it (infra/alb.tf). A String parameter: the
# app stack writes the value into its listener rules, and the CI roles'
# ReadOnlyAccess can't decrypt SecureStrings. It grants nothing a visitor
# can't already do through CloudFront.
resource "random_password" "origin_verify" {
  length  = 40
  special = false
}

resource "aws_ssm_parameter" "origin_verify" {
  name        = "/${var.project}/edge/origin-verify"
  description = "X-Origin-Verify header value CloudFront adds to demo requests (bootstrap/edge.tf)."
  type        = "String"
  value       = random_password.origin_verify.result

  #checkov:skip=CKV2_AWS_34:Not a credential, and the app stack must read it with ReadOnlyAccess; see above
}

# --- Blocklist -----------------------------------------------------------------

# Keys are viewer IP addresses; values say when and why (scripts/edge.sh).
# Terraform creates the store but never manages its keys.
resource "aws_cloudfront_key_value_store" "blocklist" {
  name    = "${var.project}-blocklist"
  comment = "Viewer IPs CloudFront refuses; managed by scripts/edge.sh"
}

resource "aws_cloudfront_function" "blocklist" {
  name    = "${var.project}-blocklist"
  runtime = "cloudfront-js-2.0"
  comment = "Refuses viewers whose IP is in the blocklist"
  publish = true
  code = templatefile("${path.module}/functions/blocklist.js", {
    kvs_id = element(split("/", aws_cloudfront_key_value_store.blocklist.arn), 1)
  })

  key_value_store_associations = [aws_cloudfront_key_value_store.blocklist.arn]
}

# --- Demo and Grafana distributions ---------------------------------------------

# Everything the viewer sent, Host included, so the ALB can route by name.
data "aws_cloudfront_origin_request_policy" "all_viewer" {
  name = "Managed-AllViewer"
}

resource "aws_cloudfront_distribution" "edge" {
  for_each = local.edge_hosts

  enabled         = true
  comment         = "${var.project} ${each.key} (on-demand demo)"
  aliases         = [each.value]
  http_version    = "http2and3"
  is_ipv6_enabled = true
  price_class     = "PriceClass_100"
  web_acl_id      = local.web_acl_arn

  # The ALB's certificate covers *.<domain>; with Host forwarded, CloudFront
  # checks it against the viewer's host name, demo or grafana.
  origin {
    origin_id   = "demo"
    domain_name = local.origin_fqdn

    custom_header {
      name  = "X-Origin-Verify"
      value = random_password.origin_verify.result
    }

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  origin {
    origin_id                = "site"
    domain_name              = aws_s3_bucket.site.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.site.id
  }

  # Nothing is cached: the dashboards, the "served by" panel and load-test
  # latencies must come from the app every time.
  default_cache_behavior {
    target_origin_id           = "demo"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods             = ["GET", "HEAD"]
    compress                   = true
    cache_policy_id            = data.aws_cloudfront_cache_policy.disabled.id
    origin_request_policy_id   = data.aws_cloudfront_origin_request_policy.all_viewer.id
    response_headers_policy_id = data.aws_cloudfront_response_headers_policy.security.id

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.blocklist.arn
    }
  }

  # Not cached either, so a new page shows without invalidating these.
  ordered_cache_behavior {
    path_pattern               = local.offline_page
    target_origin_id           = "site"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD"]
    cached_methods             = ["GET", "HEAD"]
    compress                   = true
    cache_policy_id            = data.aws_cloudfront_cache_policy.disabled.id
    response_headers_policy_id = data.aws_cloudfront_response_headers_policy.security.id

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.blocklist.arn
    }
  }

  # Demo off (the origin doesn't resolve), starting, or not answering. A 503,
  # so the launcher's health check (launcher/handler.py) still reads "down".
  dynamic "custom_error_response" {
    for_each = [502, 503, 504]

    content {
      error_code            = custom_error_response.value
      response_code         = 503
      response_page_path    = local.offline_page
      error_caching_min_ttl = 0
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.edge.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  #checkov:skip=CKV_AWS_68:WAF is optional (var.waf_enabled), turned on only when abuse is seen
  #checkov:skip=CKV2_AWS_47:WAF is optional (var.waf_enabled), turned on only when abuse is seen
  #checkov:skip=CKV_AWS_86:Access logs go to CloudWatch Logs through a log delivery (standard logging v2) below
  #checkov:skip=CKV_AWS_310:The demo is one ALB; the error responses already cover it being down
  #checkov:skip=CKV_AWS_374:A public demo; no country is excluded
  #checkov:skip=CKV_AWS_305:The app serves its own root page
}

resource "aws_route53_record" "edge" {
  for_each = {
    for pair in setproduct(keys(local.edge_hosts), ["A", "AAAA"]) :
    "${pair[0]}-${pair[1]}" => { host = pair[0], type = pair[1] }
  }

  zone_id = aws_route53_zone.main.zone_id
  name    = local.edge_hosts[each.value.host]
  type    = each.value.type

  alias {
    name                   = aws_cloudfront_distribution.edge[each.value.host].domain_name
    zone_id                = aws_cloudfront_distribution.edge[each.value.host].hosted_zone_id
    evaluate_target_health = false
  }
}

# --- Access logs ---------------------------------------------------------------

# Standard logging (v2) from all three distributions into one log group, a few
# hundred bytes per request. CloudFront delivers from us-east-1.
resource "aws_cloudwatch_log_group" "edge" {
  region            = "us-east-1"
  name              = "/aws/vendedlogs/cloudfront/${var.project}"
  retention_in_days = 7

  #checkov:skip=CKV_AWS_158:Default CloudWatch encryption; a KMS key costs $1/month
  #checkov:skip=CKV_AWS_338:A week is enough to find an abusive IP
}

resource "aws_cloudwatch_log_delivery_source" "edge" {
  for_each = local.distributions

  region       = "us-east-1"
  name         = "${var.project}-${each.key}"
  log_type     = "ACCESS_LOGS"
  resource_arn = each.value.arn
}

resource "aws_cloudwatch_log_delivery_destination" "edge" {
  region        = "us-east-1"
  name          = "${var.project}-edge"
  output_format = "json"

  delivery_destination_configuration {
    destination_resource_arn = aws_cloudwatch_log_group.edge.arn
  }
}

resource "aws_cloudwatch_log_delivery" "edge" {
  for_each = aws_cloudwatch_log_delivery_source.edge

  region                   = "us-east-1"
  delivery_source_name     = each.value.name
  delivery_destination_arn = aws_cloudwatch_log_delivery_destination.edge.arn
}

# --- Traffic alarm ---------------------------------------------------------------

# CloudFront's metrics live in us-east-1, and an alarm notifies only a topic in
# its own region, so this topic mirrors alerts.tf there.
resource "aws_sns_topic" "edge_alerts" {
  region = "us-east-1"
  name   = "${var.project}-edge-alerts"

  #checkov:skip=CKV_AWS_26:CloudWatch cannot publish to the AWS managed key; see alerts.tf
}

resource "aws_sns_topic_subscription" "edge_alerts_email" {
  region    = "us-east-1"
  topic_arn = aws_sns_topic.edge_alerts.arn
  protocol  = "email"
  endpoint  = var.budget_alert_email
}

# Requests to all three distributions together. The burst load test peaks near
# 36,000 in 15 minutes, so the default threshold leaves room for testing.
resource "aws_cloudwatch_metric_alarm" "edge_requests" {
  region              = "us-east-1"
  alarm_name          = "${var.project}-edge-requests"
  alarm_description   = "Unusually many requests to the resume, demo and Grafana. Find the busiest IPs with scripts/edge.sh top (README, Unexpected traffic)."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = var.edge_requests_alarm
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.edge_alerts.arn]
  ok_actions          = [aws_sns_topic.edge_alerts.arn]

  dynamic "metric_query" {
    for_each = local.distributions

    content {
      id = "r_${metric_query.key}"

      metric {
        namespace   = "AWS/CloudFront"
        metric_name = "Requests"
        period      = 900
        stat        = "Sum"
        dimensions  = { DistributionId = metric_query.value.id, Region = "Global" }
      }
    }
  }

  metric_query {
    id          = "total"
    expression  = "SUM(METRICS())"
    label       = "Requests, all distributions"
    return_data = true
  }
}

# --- WAF (only when needed) --------------------------------------------------------

# One web ACL for all three distributions: $5/month, $1 per rule, and $0.60
# per million requests. Turn on with waf_enabled = true and a bootstrap apply.
resource "aws_wafv2_web_acl" "edge" {
  count = var.waf_enabled ? 1 : 0

  region      = "us-east-1"
  name        = "${var.project}-edge"
  description = "Per-IP rate limit and AWS IP reputation list, turned on when abuse is seen"
  scope       = "CLOUDFRONT"

  default_action {
    allow {}
  }

  # Blocks an IP for as long as it stays over the limit. Requests with the
  # load-test token are exempt: the k6 tests and the background traffic each
  # come from a single IP.
  rule {
    name     = "rate-limit-per-ip"
    priority = 1

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit                 = var.waf_rate_limit
        evaluation_window_sec = 300
        aggregate_key_type    = "IP"

        scope_down_statement {
          not_statement {
            statement {
              byte_match_statement {
                search_string         = random_password.load_test_token.result
                positional_constraint = "EXACTLY"

                field_to_match {
                  single_header {
                    name = "x-load-test-token"
                  }
                }

                text_transformation {
                  priority = 0
                  type     = "NONE"
                }
              }
            }
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "rate-limit-per-ip"
      sampled_requests_enabled   = true
    }
  }

  # Addresses Amazon's threat intelligence has seen in bots and attacks.
  rule {
    name     = "aws-ip-reputation"
    priority = 2

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesAmazonIpReputationList"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "aws-ip-reputation"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.project}-edge"
    sampled_requests_enabled   = true
  }

  #checkov:skip=CKV2_AWS_31:Sampled requests and metrics are enough for a temporary ACL; full logging bills per GB
  #checkov:skip=CKV_AWS_192:Log4j rules cost another $1/month; the app is Python with no Java
}
