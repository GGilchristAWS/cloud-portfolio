# Cost guardrails for a pay-as-you-go account. Budgets without actions and
# Cost Anomaly Detection are free.
#
#   daily   - catches a stack left running: the demo stack costs ~$1/day
#   monthly - tracks the actual bill (credits applied) against a small ceiling
#   anomaly - flags unusual per-service spend, independent of fixed thresholds
#
# Budget data refreshes a few times a day, so alerts can lag by several hours.

resource "aws_budgets_budget" "daily" {
  name         = "${var.project}-daily"
  budget_type  = "COST"
  limit_amount = tostring(var.daily_budget_usd)
  limit_unit   = "USD"
  time_unit    = "DAILY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_alert_email]
  }
}

resource "aws_budgets_budget" "monthly" {
  name         = "${var.project}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  dynamic "notification" {
    for_each = [
      { type = "ACTUAL", threshold = 50 },
      { type = "ACTUAL", threshold = 80 },
      { type = "ACTUAL", threshold = 100 },
      { type = "FORECASTED", threshold = 100 },
    ]

    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value.threshold
      threshold_type             = "PERCENTAGE"
      notification_type          = notification.value.type
      subscriber_email_addresses = [var.budget_alert_email]
    }
  }
}

# AWS creates a default service monitor and subscription in new accounts. They
# are adopted into Terraform here because the default alert threshold ($100 and
# 40% impact) would never fire for an account this small.

import {
  to = aws_ce_anomaly_monitor.services
  id = "arn:aws:ce::${data.aws_caller_identity.current.account_id}:anomalymonitor/85747299-2e9c-4109-8aa3-530bbf9d245b"
}

import {
  to = aws_ce_anomaly_subscription.services
  id = "arn:aws:ce::${data.aws_caller_identity.current.account_id}:anomalysubscription/ad546581-78f1-46b7-b988-bb4e1e1bb07d"
}

resource "aws_ce_anomaly_monitor" "services" {
  name              = "Default-Services-Monitor"
  monitor_type      = "DIMENSIONAL"
  monitor_dimension = "SERVICE"
}

resource "aws_ce_anomaly_subscription" "services" {
  name             = "Default-Services-Subscription"
  frequency        = "DAILY"
  monitor_arn_list = [aws_ce_anomaly_monitor.services.arn]

  subscriber {
    type    = "EMAIL"
    address = var.budget_alert_email
  }

  threshold_expression {
    dimension {
      key           = "ANOMALY_TOTAL_IMPACT_ABSOLUTE"
      match_options = ["GREATER_THAN_OR_EQUAL"]
      values        = [tostring(var.anomaly_threshold_usd)]
    }
  }
}
