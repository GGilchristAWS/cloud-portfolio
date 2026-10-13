# What the deploy role may change: the app stack (infra/) and the image
# registry. Reads come from ReadOnlyAccess; writes are listed explicitly.
# All regional actions are limited to var.aws_region.

locals {
  account_id = data.aws_caller_identity.current.account_id
  app_roles  = "arn:aws:iam::${local.account_id}:role/${var.project}-*"

  # Managed policies the app stack may attach to its roles. Anything else
  # would let the deploy role grant itself new permissions through a task.
  attachable_policies = [
    "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy",
    "arn:aws:iam::aws:policy/CloudWatchReadOnlyAccess", # Grafana's CloudWatch data source
    aws_iam_policy.grafana_secret_read.arn,
  ]

  # Names the app stack may point at its load balancer.
  app_record_names = [lower(local.app_fqdn), "grafana.${lower(var.domain_name)}"]
}

resource "aws_iam_role_policy_attachment" "github_deploy_readonly" {
  role       = aws_iam_role.github_deploy.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

data "aws_iam_policy_document" "github_deploy_app" {
  statement {
    sid = "Networking"
    actions = [
      "ec2:CreateVpc", "ec2:DeleteVpc", "ec2:ModifyVpcAttribute",
      "ec2:CreateSubnet", "ec2:DeleteSubnet", "ec2:ModifySubnetAttribute",
      "ec2:CreateInternetGateway", "ec2:DeleteInternetGateway",
      "ec2:AttachInternetGateway", "ec2:DetachInternetGateway",
      "ec2:CreateRouteTable", "ec2:DeleteRouteTable", "ec2:CreateRoute", "ec2:DeleteRoute",
      "ec2:ReplaceRoute", "ec2:AssociateRouteTable", "ec2:DisassociateRouteTable",
      "ec2:CreateSecurityGroup", "ec2:DeleteSecurityGroup", "ec2:ModifySecurityGroupRules",
      "ec2:AuthorizeSecurityGroupIngress", "ec2:AuthorizeSecurityGroupEgress",
      "ec2:RevokeSecurityGroupIngress", "ec2:RevokeSecurityGroupEgress",
      "ec2:UpdateSecurityGroupRuleDescriptionsIngress",
      "ec2:UpdateSecurityGroupRuleDescriptionsEgress",
      "ec2:CreateTags", "ec2:DeleteTags",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
  }

  statement {
    sid       = "LoadBalancingAndContainers"
    actions   = ["elasticloadbalancing:*", "ecs:*", "servicediscovery:*"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
  }

  statement {
    sid       = "AppLogGroups"
    actions   = ["logs:*"]
    resources = ["arn:aws:logs:${var.aws_region}:${local.account_id}:log-group:/ecs/${var.project}*"]
  }

  statement {
    sid = "AlarmsAndDashboards"
    actions = [
      "cloudwatch:PutMetricAlarm", "cloudwatch:DeleteAlarms",
      "cloudwatch:PutDashboard", "cloudwatch:DeleteDashboards",
      "cloudwatch:TagResource", "cloudwatch:UntagResource",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
  }

  # IAM is the privilege-escalation path, so it is the tightest: only roles
  # named <project>-*, only the policies in local.attachable_policies may be
  # attached, and roles may only be passed to ECS tasks.
  statement {
    sid = "AppRoles"
    actions = [
      "iam:CreateRole", "iam:DeleteRole", "iam:TagRole", "iam:UntagRole",
      "iam:UpdateRole", "iam:UpdateAssumeRolePolicy",
    ]
    resources = [local.app_roles]
  }

  statement {
    sid       = "AppRolePolicies"
    actions   = ["iam:AttachRolePolicy", "iam:DetachRolePolicy"]
    resources = [local.app_roles]

    condition {
      test     = "ArnEquals"
      variable = "iam:PolicyARN"
      values   = local.attachable_policies
    }
  }

  statement {
    sid       = "PassAppRolesToEcs"
    actions   = ["iam:PassRole"]
    resources = [local.app_roles]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }

  # ECS and ELB create their service-linked roles on first use in an account.
  statement {
    sid       = "ServiceLinkedRoles"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values   = ["ecs.amazonaws.com", "elasticloadbalancing.amazonaws.com"]
    }
  }

  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "EcrPush"
    actions = [
      "ecr:BatchCheckLayerAvailability", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload", "ecr:PutImage",
    ]
    resources = [aws_ecr_repository.app.arn, aws_ecr_repository.obs_config.arn]
  }

  # The app stack creates and deletes only the app's and Grafana's alias records.
  statement {
    sid       = "AppDnsRecord"
    actions   = ["route53:ChangeResourceRecordSets"]
    resources = [aws_route53_zone.main.arn]

    # Both keys are multivalued (one request can change several records), so
    # ForAllValues requires every record in the request to match. ForAllValues
    # is also true when a key is absent, so each key is required by a Null check.
    condition {
      test     = "ForAllValues:StringEquals"
      variable = "route53:ChangeResourceRecordSetsNormalizedRecordNames"
      values   = local.app_record_names
    }

    condition {
      test     = "Null"
      variable = "route53:ChangeResourceRecordSetsNormalizedRecordNames"
      values   = ["false"]
    }

    # A alias to the ALB only: no CNAME/NS/TXT records that could redirect or
    # re-delegate the name, or answer certificate validation challenges.
    condition {
      test     = "ForAllValues:StringEquals"
      variable = "route53:ChangeResourceRecordSetsRecordTypes"
      values   = ["A"]
    }

    condition {
      test     = "Null"
      variable = "route53:ChangeResourceRecordSetsRecordTypes"
      values   = ["false"]
    }
  }
}

resource "aws_iam_role_policy" "github_deploy_app" {
  name   = "app-stack-deploy"
  role   = aws_iam_role.github_deploy.id
  policy = data.aws_iam_policy_document.github_deploy_app.json
}
