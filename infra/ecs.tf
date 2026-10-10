# The ECR repository is created by the bootstrap stack so images outlive this stack.
data "aws_ecr_repository" "app" {
  name = var.project
}

locals {
  capacity_provider = var.use_spot ? "FARGATE_SPOT" : "FARGATE"
  container_name    = "app"
}

resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${var.project}"
  retention_in_days = var.log_retention_days

  #checkov:skip=CKV_AWS_158:Default CloudWatch encryption; a KMS key costs $1/month
  #checkov:skip=CKV_AWS_338:7-day retention keeps log storage near zero for a demo
}

# Container Insights is left off: it bills per metric and adds little for one task.
resource "aws_ecs_cluster" "this" {
  name = var.project

  #checkov:skip=CKV_AWS_65:Container Insights bills per metric; ALB metrics cover this service

  setting {
    name  = "containerInsights"
    value = "disabled"
  }
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name       = aws_ecs_cluster.this.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = local.capacity_provider
    weight            = 1
  }
}

# --- Task execution role (pulls the image, writes logs) --------------------

data "aws_iam_policy_document" "ecs_tasks_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:*"]
    }
  }
}

resource "aws_iam_role" "execution" {
  name               = "${var.project}-ecs-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_trust.json
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# The app makes no AWS API calls, so the task has no task role.

resource "aws_ecs_task_definition" "app" {
  family                   = var.project
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.execution.arn

  # Fargate Spot supports X86_64 only.
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([
    {
      name                   = local.container_name
      image                  = "${data.aws_ecr_repository.app.repository_url}:${var.image_tag}"
      essential              = true
      readonlyRootFilesystem = true

      portMappings = [
        { containerPort = var.container_port, protocol = "tcp" }
      ]

      healthCheck = {
        command = [
          "CMD", "python", "-c",
          "import urllib.request; urllib.request.urlopen('http://127.0.0.1:${var.container_port}/health', timeout=2)",
        ]
        interval    = 15
        timeout     = 5
        retries     = 3
        startPeriod = 10
      }

      linuxParameters = {
        initProcessEnabled = true
      }

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.app.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = local.container_name
        }
      }
    }
  ])
}

resource "aws_ecs_service" "app" {
  name            = var.project
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = var.desired_count

  #checkov:skip=CKV_AWS_333:No NAT gateway by design; the security group admits only the ALB

  capacity_provider_strategy {
    capacity_provider = local.capacity_provider
    weight            = 1
  }

  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.tasks.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = local.container_name
    container_port   = var.container_port
  }

  # Start the new task before stopping the old one; roll back automatically
  # if the new task never becomes healthy.
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  health_check_grace_period_seconds  = 30

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  propagate_tags          = "SERVICE"
  enable_ecs_managed_tags = true

  # terraform apply (and therefore the CI deploy job) fails if the rollout does.
  wait_for_steady_state = true

  depends_on = [
    aws_lb_listener.http,
    aws_ecs_cluster_capacity_providers.this,
    aws_iam_role_policy_attachment.execution,
  ]
}
