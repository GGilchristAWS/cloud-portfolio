# HTTPS on 443 with the bootstrap stack's ACM certificate; port 80 only
# redirects to HTTPS. TLS terminates here; ALB-to-task traffic stays in the VPC.

resource "aws_lb" "this" {
  name               = var.project
  load_balancer_type = "application"
  internal           = false
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  drop_invalid_header_fields = true

  #checkov:skip=CKV_AWS_150:The stack is rebuilt by Terraform; teardown must not need a manual step
  #checkov:skip=CKV_AWS_91:Access logs need an S3 bucket with an ELB policy; not worth it for a demo
  #checkov:skip=CKV2_AWS_28:WAF costs $5+/month per web ACL plus rules
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
    interval            = 15
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
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}
