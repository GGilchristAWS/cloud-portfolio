# HTTPS on 443 with the bootstrap stack's ACM certificate, from CloudFront
# only (bootstrap/edge.tf): the security group admits CloudFront's address
# ranges, and the listener forwards only requests carrying the X-Origin-Verify
# header that our distributions add. Anything else gets a 403. TLS terminates
# here; ALB-to-task traffic stays in the VPC.

locals {
  origin_verify_header = "X-Origin-Verify"
}

data "aws_ssm_parameter" "origin_verify" {
  name = "/${var.project}/edge/origin-verify"
}

resource "aws_lb" "this" {
  name               = var.project
  load_balancer_type = "application"
  internal           = false
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  drop_invalid_header_fields = true

  #checkov:skip=CKV_AWS_150:On-demand demo stack, destroyed after every session by design
  #checkov:skip=CKV_AWS_91:Access logs need an S3 bucket with an ELB policy; not worth it for a demo
  #checkov:skip=CKV2_AWS_28:Only CloudFront reaches it; WAF, when on, sits there (bootstrap/edge.tf)
}

resource "aws_lb_target_group" "app" {
  name        = "${var.project}-app"
  port        = var.container_port
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = aws_vpc.this.id

  #checkov:skip=CKV_AWS_378:ALB-to-task traffic stays inside the VPC and is restricted by security groups

  # Short drain keeps deployments and teardowns fast for a demo.
  deregistration_delay = 30

  health_check {
    path                = "/health"
    matcher             = "200"
    interval            = 10 # with 2 healthy checks, a new task takes traffic 20 s after it starts
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

# TLS 1.3/1.2 with restricted ciphers and hybrid post-quantum key exchange;
# clients without PQ support negotiate classical key exchange.
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-Res-PQ-2025-09"
  certificate_arn   = data.aws_acm_certificate.main.arn

  # HSTS: browsers that have visited once refuse plain HTTP for a year.
  routing_http_response_strict_transport_security_header_value = "max-age=31536000; includeSubDomains"

  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "Forbidden"
      status_code  = "403"
    }
  }
}

# Grafana's rules (observability.tf) come first, at priorities 10 and 20.
resource "aws_lb_listener_rule" "app" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 100

  condition {
    http_header {
      http_header_name = local.origin_verify_header
      values           = [data.aws_ssm_parameter.origin_verify.value]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}
