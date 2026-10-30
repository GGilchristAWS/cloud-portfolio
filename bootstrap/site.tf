# The always-on front door: the resume as a static page at the zone apex,
# served by CloudFront from a private S3 bucket, with the demo launcher
# (launcher.tf) under /api/. The demo itself (infra/) runs only on demand, at
# demo.<domain>. Costs cents a month; CI uploads the page (deploy.yml).
#
#   https://<domain>  -> CloudFront -+-> /*      S3 (index.html)
#                                    +-> /api/*  launcher function URL

resource "aws_s3_bucket" "site" {
  bucket = "${var.project}-site-${local.account_id}"

  #checkov:skip=CKV_AWS_21:Content is rebuilt from git on every deploy; versions add nothing
  #checkov:skip=CKV_AWS_144:Single-region demo; the content lives in git
  #checkov:skip=CKV_AWS_145:SSE-S3 instead of a KMS key to avoid $1/month per key
  #checkov:skip=CKV_AWS_18:Access logging needs a second bucket; CloudTrail already records API access
  #checkov:skip=CKV2_AWS_62:Nothing consumes bucket event notifications
  #checkov:skip=CKV2_AWS_61:A single small page; nothing to expire
}

resource "aws_s3_bucket_public_access_block" "site" {
  bucket = aws_s3_bucket.site.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "site" {
  bucket = aws_s3_bucket.site.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "site" {
  bucket = aws_s3_bucket.site.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Only this distribution may read the bucket.
data "aws_iam_policy_document" "site_bucket" {
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.site.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [aws_cloudfront_distribution.site.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "site" {
  bucket = aws_s3_bucket.site.id
  policy = data.aws_iam_policy_document.site_bucket.json

  depends_on = [aws_s3_bucket_public_access_block.site]
}

# CloudFront takes certificates only from us-east-1, so the regional wildcard
# in dns.tf can't be reused.
resource "aws_acm_certificate" "site" {
  region            = "us-east-1"
  domain_name       = var.domain_name
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

# ACM usually asks for the same validation record as the regional certificate
# for this name; allow_overwrite lets both resources write it.
resource "aws_route53_record" "site_cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.site.domain_validation_options : dvo.domain_name => {
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

resource "aws_acm_certificate_validation" "site" {
  region                  = "us-east-1"
  certificate_arn         = aws_acm_certificate.site.arn
  validation_record_fqdns = [for record in aws_route53_record.site_cert_validation : record.fqdn]
}

resource "aws_cloudfront_origin_access_control" "site" {
  name                              = "${var.project}-site"
  description                       = "CloudFront to the site bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_origin_access_control" "launcher" {
  name                              = "${var.project}-launcher"
  description                       = "CloudFront to the demo launcher's function URL"
  origin_access_control_origin_type = "lambda"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

data "aws_cloudfront_cache_policy" "optimized" {
  name = "Managed-CachingOptimized"
}

data "aws_cloudfront_cache_policy" "disabled" {
  name = "Managed-CachingDisabled"
}

# A function URL answers only to its own host name, so the viewer's Host
# header must not be forwarded.
data "aws_cloudfront_origin_request_policy" "all_except_host" {
  name = "Managed-AllViewerExceptHostHeader"
}

# HSTS, nosniff, frame and referrer headers.
data "aws_cloudfront_response_headers_policy" "security" {
  name = "Managed-SecurityHeadersPolicy"
}

resource "aws_cloudfront_distribution" "site" {
  enabled             = true
  comment             = "${var.project} resume and demo launcher"
  aliases             = [var.domain_name]
  default_root_object = "index.html"
  http_version        = "http2and3"
  is_ipv6_enabled     = true
  price_class         = "PriceClass_100"

  origin {
    origin_id                = "site"
    domain_name              = aws_s3_bucket.site.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.site.id
  }

  origin {
    origin_id                = "launcher"
    domain_name              = split("/", aws_lambda_function_url.launcher.function_url)[2]
    origin_access_control_id = aws_cloudfront_origin_access_control.launcher.id

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    target_origin_id           = "site"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD"]
    cached_methods             = ["GET", "HEAD"]
    compress                   = true
    cache_policy_id            = data.aws_cloudfront_cache_policy.optimized.id
    response_headers_policy_id = data.aws_cloudfront_response_headers_policy.security.id
  }

  ordered_cache_behavior {
    path_pattern               = "/api/*"
    target_origin_id           = "launcher"
    viewer_protocol_policy     = "https-only"
    allowed_methods            = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods             = ["GET", "HEAD"]
    compress                   = true
    cache_policy_id            = data.aws_cloudfront_cache_policy.disabled.id
    origin_request_policy_id   = data.aws_cloudfront_origin_request_policy.all_except_host.id
    response_headers_policy_id = data.aws_cloudfront_response_headers_policy.security.id
  }

  # The bucket isn't listable, so a missing page is a 403 from S3. Old links to
  # /resume, and any other path, land on the resume.
  custom_error_response {
    error_code         = 403
    response_code      = 404
    response_page_path = "/index.html"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.site.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  #checkov:skip=CKV_AWS_68:WAF costs $5+/month per web ACL plus rules
  #checkov:skip=CKV2_AWS_47:WAF costs $5+/month per web ACL plus rules
  #checkov:skip=CKV_AWS_86:Access logs need a logging bucket; not worth it for one static page
  #checkov:skip=CKV_AWS_310:One origin per path; S3 and Lambda are already regional and highly available
  #checkov:skip=CKV_AWS_374:A public resume; no country is excluded
}

resource "aws_route53_record" "site" {
  for_each = toset(["A", "AAAA"])

  zone_id = aws_route53_zone.main.zone_id
  name    = var.domain_name
  type    = each.key

  alias {
    name                   = aws_cloudfront_distribution.site.domain_name
    zone_id                = aws_cloudfront_distribution.site.hosted_zone_id
    evaluate_target_health = false
  }
}
