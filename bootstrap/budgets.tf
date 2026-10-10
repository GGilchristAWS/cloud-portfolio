# Budgets track gross usage (credits excluded) so alerts fire when free-tier
# credits are being consumed, not only once real money is spent.
# The first two budgets in an account are free.

locals {
  budget_cost_types = {
    include_credit = false
    include_refund = false
  }
}

resource "aws_budgets_budget" "zero_spend" {
  name         = "${var.project}-zero-spend"
  budget_type  = "COST"
  limit_amount = "1.0"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_types {
    include_credit = local.budget_cost_types.include_credit
    include_refund = local.budget_cost_types.include_refund
  }

  # Fires as soon as gross usage exceeds $0.01.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 1
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

  cost_types {
    include_credit = local.budget_cost_types.include_credit
    include_refund = local.budget_cost_types.include_refund
  }

  dynamic "notification" {
    for_each = [
      { type = "ACTUAL", threshold = 50 },
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
