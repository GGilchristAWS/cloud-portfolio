# Observability stack: one Fargate Spot task running the OpenTelemetry
# Collector, Prometheus, Loki, Tempo and Grafana side by side. Containers in
# a task share localhost, so the configs in obs/config address each other on
# 127.0.0.1 (the same wiring as obs/compose.yaml for local runs).
#
#   app task --OTLP--> otel-collector:4318 (ECS Service Connect)
#   internet --HTTPS--> CloudFront --> ALB --host grafana.<domain>--> Grafana :3000
#
# Telemetry lives as long as the task does: one demo session, since the
# stack is torn down a couple of hours after each launch. The config image is built from obs/ by CI.

locals {
  grafana_fqdn = "grafana.${var.domain_name}"

  # Image versions are pinned once, in obs/compose.yaml: the local stack, CI's
  # config validation and this task all run exactly the same versions, and a
  # Dependabot bump there is a one-line change.
  compose_services = yamldecode(file("${path.module}/../obs/compose.yaml")).services
  obs_images = {
    collector  = local.compose_services["otel-collector"].image
    prometheus = local.compose_services.prometheus.image
    loki       = local.compose_services.loki.image
    tempo      = local.compose_services.tempo.image
    grafana    = local.compose_services.grafana.image
    k6         = local.compose_services.k6.image
  }
  obs_log_options = {
    "awslogs-group"  = aws_cloudwatch_log_group.monitoring.name
    "awslogs-region" = var.aws_region
  }
  config_mount = [{ sourceVolume = "config", containerPath = "/etc/obs", readOnly = true }]
}

data "aws_ecr_repository" "obs_config" {
  name = "${var.project}-obs-config"
}

data "aws_ssm_parameter" "grafana_admin_password" {
  name            = "/${var.project}/grafana/admin-password"
  with_decryption = false # only the ARN is used; ECS injects the value
}

data "aws_iam_policy" "grafana_secret_read" {
  name = "${var.project}-grafana-secret-read"
}

resource "aws_cloudwatch_log_group" "monitoring" {
  name              = "/ecs/${var.project}-monitoring"
  retention_in_days = var.log_retention_days

  #checkov:skip=CKV_AWS_158:Default CloudWatch encryption; a KMS key costs $1/month
  #checkov:skip=CKV_AWS_338:7-day retention keeps log storage near zero for a demo
}

# --- Service Connect: lets the app reach the collector by name --------------

resource "aws_service_discovery_http_namespace" "this" {
  name        = var.project
  description = "Service Connect namespace for the app and monitoring services"
}

# --- Monitoring task ----------------------------------------------------------

resource "aws_iam_role" "monitoring_execution" {
  name               = "${var.project}-monitoring-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_trust.json
}

resource "aws_iam_role_policy_attachment" "monitoring_execution" {
  for_each = {
    ecs       = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
    grafana   = data.aws_iam_policy.grafana_secret_read.arn
    load_test = data.aws_iam_policy.load_test_token_read.arn # the traffic container
  }

  role       = aws_iam_role.monitoring_execution.name
  policy_arn = each.value
}

# Task role: what the containers themselves may call. Grafana's CloudWatch
# data source reads metrics with it; nothing else in the task uses AWS APIs.
resource "aws_iam_role" "monitoring_task" {
  name               = "${var.project}-monitoring-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_trust.json
}

# Metrics only (bootstrap/observability.tf): anonymous viewers' queries run
# with this role, so it must not read CloudWatch Logs.
data "aws_iam_policy" "grafana_cloudwatch_metrics" {
  name = "${var.project}-grafana-cloudwatch-metrics"
}

resource "aws_iam_role_policy_attachment" "monitoring_task_cloudwatch" {
  role       = aws_iam_role.monitoring_task.name
  policy_arn = data.aws_iam_policy.grafana_cloudwatch_metrics.arn
}

resource "aws_ecs_task_definition" "monitoring" {
  family                   = "${var.project}-monitoring"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.monitoring_cpu
  memory                   = var.monitoring_memory
  execution_role_arn       = aws_iam_role.monitoring_execution.arn
  task_role_arn            = aws_iam_role.monitoring_task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  # Task-local scratch volume the config container fills before the rest start.
  volume {
    name = "config"
  }

  container_definitions = jsonencode([
    {
      name        = "config"
      image       = "${data.aws_ecr_repository.obs_config.repository_url}:${var.obs_config_tag}"
      essential   = false
      mountPoints = [{ sourceVolume = "config", containerPath = "/etc/obs", readOnly = false }]
      logConfiguration = {
        logDriver = "awslogs"
        options   = merge(local.obs_log_options, { "awslogs-stream-prefix" = "config" })
      }
    },
    {
      name              = "prometheus"
      image             = local.obs_images.prometheus
      essential         = true
      memoryReservation = 768
      command = [
        "--config.file=/etc/obs/prometheus/prometheus.yml",
        "--web.enable-otlp-receiver",
        "--web.enable-remote-write-receiver",
        "--enable-feature=exemplar-storage",
        "--storage.tsdb.retention.time=1d",
      ]
      mountPoints = local.config_mount
      dependsOn   = [{ containerName = "config", condition = "SUCCESS" }]
      logConfiguration = {
        logDriver = "awslogs"
        options   = merge(local.obs_log_options, { "awslogs-stream-prefix" = "prometheus" })
      }
    },
    {
      name              = "loki"
      image             = local.obs_images.loki
      essential         = true
      memoryReservation = 384
      command           = ["-config.file=/etc/obs/loki/loki.yaml"]
      mountPoints       = local.config_mount
      dependsOn         = [{ containerName = "config", condition = "SUCCESS" }]
      logConfiguration = {
        logDriver = "awslogs"
        options   = merge(local.obs_log_options, { "awslogs-stream-prefix" = "loki" })
      }
    },
    {
      name              = "tempo"
      image             = local.obs_images.tempo
      essential         = true
      memoryReservation = 512
      command           = ["-target=all", "-config.file=/etc/obs/tempo/tempo.yaml"]
      mountPoints       = local.config_mount
      dependsOn         = [{ containerName = "config", condition = "SUCCESS" }]
      logConfiguration = {
        logDriver = "awslogs"
        options   = merge(local.obs_log_options, { "awslogs-stream-prefix" = "tempo" })
      }
    },
    {
      name              = "grafana"
      image             = local.obs_images.grafana
      essential         = true
      memoryReservation = 256
      portMappings      = [{ name = "grafana", containerPort = 3000, protocol = "tcp" }]
      mountPoints       = local.config_mount
      dependsOn         = [{ containerName = "config", condition = "SUCCESS" }]
      environment = [
        for k, v in {
          GF_PATHS_PROVISIONING                     = "/etc/obs/grafana/provisioning"
          GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH = "/etc/obs/grafana/dashboards/portfolio-overview.json"
          GF_SERVER_ROOT_URL                        = "https://${local.grafana_fqdn}"
          GF_AUTH_ANONYMOUS_ENABLED                 = "true"
          GF_AUTH_ANONYMOUS_ORG_ROLE                = "Viewer"
          GF_AUTH_ANONYMOUS_HIDE_VERSION            = "true"
          GF_USERS_ALLOW_SIGN_UP                    = "false"
          GF_SECURITY_COOKIE_SECURE                 = "true"
          GF_SECURITY_DISABLE_GRAVATAR              = "true"
          GF_ANALYTICS_REPORTING_ENABLED            = "false"
          GF_ANALYTICS_CHECK_FOR_UPDATES            = "false"
        } : { name = k, value = v }
      ]
      secrets = [
        { name = "GF_SECURITY_ADMIN_PASSWORD", valueFrom = data.aws_ssm_parameter.grafana_admin_password.arn }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options   = merge(local.obs_log_options, { "awslogs-stream-prefix" = "grafana" })
      }
    },
    {
      # Starts last so the backends are listening when telemetry arrives.
      name              = "otel-collector"
      image             = local.obs_images.collector
      essential         = true
      memoryReservation = 256
      command           = ["--config=/etc/obs/collector/config.yaml", "--config=/etc/obs/collector/ecs.yaml"]
      portMappings      = [{ name = "otlp-http", containerPort = 4318, protocol = "tcp", appProtocol = "http" }]
      mountPoints       = local.config_mount
      dependsOn = [
        { containerName = "prometheus", condition = "START" },
        { containerName = "loki", condition = "START" },
        { containerName = "tempo", condition = "START" },
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options   = merge(local.obs_log_options, { "awslogs-stream-prefix" = "otel-collector" })
      }
    },
    {
      # Background traffic for the session (obs/config/k6/ambient.js), so the
      # dashboards aren't empty when a visitor opens them. Not essential: the
      # monitoring stack doesn't depend on it.
      name              = "traffic"
      image             = local.obs_images.k6
      essential         = false
      memoryReservation = 64
      command           = ["run", "--quiet", "--summary-mode=disabled", "/etc/obs/k6/ambient.js"]
      environment       = [{ name = "BASE_URL", value = "https://${local.app_fqdn}" }]
      secrets = [
        { name = "LOAD_TEST_TOKEN", valueFrom = data.aws_ssm_parameter.load_test_token.arn }
      ]
      mountPoints = local.config_mount
      dependsOn   = [{ containerName = "config", condition = "SUCCESS" }]
      logConfiguration = {
        logDriver = "awslogs"
        options   = merge(local.obs_log_options, { "awslogs-stream-prefix" = "traffic" })
      }
    },
  ])
}

resource "aws_ecs_service" "monitoring" {
  name            = "${var.project}-monitoring"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.monitoring.arn
  desired_count   = 1

  #checkov:skip=CKV_AWS_333:No NAT gateway by design; the security group admits only the ALB and app tasks

  capacity_provider_strategy {
    capacity_provider = local.capacity_provider
    weight            = 1
  }

  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.monitoring.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.grafana.arn
    container_name   = "grafana"
    container_port   = 3000
  }

  service_connect_configuration {
    enabled   = true
    namespace = aws_service_discovery_http_namespace.this.arn

    service {
      port_name      = "otlp-http"
      discovery_name = "otel-collector"

      client_alias {
        port     = 4318
        dns_name = "otel-collector"
      }
    }
  }

  health_check_grace_period_seconds = 60

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  propagate_tags          = "SERVICE"
  enable_ecs_managed_tags = true

  # Not waited on: the app service needs this service to exist, not to be
  # healthy (see ecs.tf), so both roll out side by side and a launch is about
  # two minutes faster. The deploy's Grafana and telemetry checks confirm it
  # came up.
  wait_for_steady_state = false

  depends_on = [
    aws_lb_listener_rule.grafana,
    aws_ecs_cluster_capacity_providers.this,
    aws_iam_role_policy_attachment.monitoring_execution,
    aws_iam_role_policy_attachment.monitoring_task_cloudwatch,
  ]
}

# --- Networking -------------------------------------------------------------

resource "aws_security_group" "monitoring" {
  name        = "${var.project}-monitoring"
  description = "Monitoring task: Grafana from the ALB, OTLP from app tasks"
  vpc_id      = aws_vpc.this.id
}

resource "aws_vpc_security_group_ingress_rule" "monitoring_from_alb" {
  security_group_id            = aws_security_group.monitoring.id
  description                  = "Grafana from the load balancer"
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = 3000
  to_port                      = 3000
}

resource "aws_vpc_security_group_ingress_rule" "monitoring_from_tasks" {
  security_group_id            = aws_security_group.monitoring.id
  description                  = "OTLP from app tasks"
  referenced_security_group_id = aws_security_group.tasks.id
  ip_protocol                  = "tcp"
  from_port                    = 4318
  to_port                      = 4318
}

resource "aws_vpc_security_group_egress_rule" "monitoring_https" {
  security_group_id = aws_security_group.monitoring.id
  description       = "HTTPS out for image pulls, CloudWatch Logs and Parameter Store"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_egress_rule" "tasks_to_monitoring" {
  security_group_id            = aws_security_group.tasks.id
  description                  = "OTLP to the collector"
  referenced_security_group_id = aws_security_group.monitoring.id
  ip_protocol                  = "tcp"
  from_port                    = 4318
  to_port                      = 4318
}

resource "aws_vpc_security_group_egress_rule" "alb_to_grafana" {
  security_group_id            = aws_security_group.alb.id
  description                  = "To Grafana"
  referenced_security_group_id = aws_security_group.monitoring.id
  ip_protocol                  = "tcp"
  from_port                    = 3000
  to_port                      = 3000
}

# --- Grafana behind the ALB ------------------------------------------------

resource "aws_lb_target_group" "grafana" {
  name                 = "${var.project}-grafana"
  port                 = 3000
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = aws_vpc.this.id
  deregistration_delay = 30

  #checkov:skip=CKV_AWS_378:ALB-to-task traffic stays inside the VPC and is restricted by security groups

  health_check {
    path                = "/api/health"
    matcher             = "200"
    interval            = 10 # with 2 healthy checks, a new task takes traffic 20 s after it starts
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

# Grafana's own /metrics is for Prometheus inside the task, not the internet.
resource "aws_lb_listener_rule" "grafana_metrics_blocked" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 10

  condition {
    host_header {
      values = [local.grafana_fqdn]
    }
  }

  condition {
    path_pattern {
      values = ["/metrics", "/metrics/*"]
    }
  }

  action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "Not found"
      status_code  = "404"
    }
  }
}

resource "aws_lb_listener_rule" "grafana" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 20

  condition {
    host_header {
      values = [local.grafana_fqdn]
    }
  }

  condition {
    http_header {
      http_header_name = local.origin_verify_header
      values           = [data.aws_ssm_parameter.origin_verify.value]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.grafana.arn
  }
}

# Something outside the stack must watch it: if the monitoring task dies, its
# own alerts die with it. CloudWatch notices Grafana disappearing from the ALB.
resource "aws_cloudwatch_metric_alarm" "monitoring_down" {
  alarm_name          = "${var.project}-monitoring-down"
  alarm_description   = "The observability stack has no healthy Grafana behind the load balancer."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HealthyHostCount"
  dimensions          = { LoadBalancer = aws_lb.this.arn_suffix, TargetGroup = aws_lb_target_group.grafana.arn_suffix }
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 5
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}
