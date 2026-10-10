# Alarm notifications for the app stack. Kept here so the email subscription
# is confirmed once, not after every rebuild of the app stack.
#
# Not KMS-encrypted: CloudWatch alarms cannot publish to a topic encrypted with
# the AWS managed SNS key, and a customer managed key costs $1/month.

resource "aws_sns_topic" "alerts" {
  name = "${var.project}-alerts"

  #checkov:skip=CKV_AWS_26:CloudWatch cannot publish to the AWS managed key; see note above
}

resource "aws_sns_topic_subscription" "alerts_email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.budget_alert_email
}
