# HTTP only: HTTPS needs a domain and an ACM certificate (a later add-on).

resource "aws_lb" "this" {
  name               = var.project
  load_balancer_type = "application"
  internal           = false
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  drop_invalid_header_fields = true

  #checkov:skip=CKV_AWS_150:Ephemeral demo stack, destroyed nightly by design
  #checkov:skip=CKV_AWS_91:Access logs need an S3 bucket with an ELB policy; not worth it for a demo
  #checkov:skip=CKV2_AWS_20:No domain, so no certificate to redirect to
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

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  #checkov:skip=CKV_AWS_2:No domain, so no ACM certificate for HTTPS
  #checkov:skip=CKV_AWS_103:No TLS listener (see CKV_AWS_2)

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}
