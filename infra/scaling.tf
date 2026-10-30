# Scales the app out when real traffic makes it work hard, and back in when
# the traffic goes. Target tracking keeps average CPU across the app's tasks
# near 60%: it adds tasks after about 3 minutes above that, and removes them
# slowly once it falls. (Load tests barely move CPU: /api/simulate only waits.)
#
# Cost ceiling, the reason for max_count = 20: the demo is up at most 12 hours
# a day (4 launches of 2 hours, each extendable by 1), about 360 hours a
# month. A task (0.5 vCPU, 1 GB) costs about $0.025/hour at the on-demand
# Fargate price, and roughly a third of that on Spot. Twenty tasks for every
# one of those hours is 20 x 360 x $0.025 = $180 at most, under the $200/month
# budget even without the Spot discount. 20 tasks (10 vCPU) also fit the
# account's 30 vCPU Fargate Spot quota with room for the monitoring task and
# a rolling deploy.

resource "aws_appautoscaling_target" "app" {
  service_namespace  = "ecs"
  scalable_dimension = "ecs:service:DesiredCount"
  resource_id        = "service/${aws_ecs_cluster.this.name}/${aws_ecs_service.app.name}"
  min_capacity       = var.desired_count
  max_capacity       = var.max_count
}

resource "aws_appautoscaling_policy" "app_cpu" {
  name               = "${var.project}-cpu"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.app.service_namespace
  scalable_dimension = aws_appautoscaling_target.app.scalable_dimension
  resource_id        = aws_appautoscaling_target.app.resource_id

  target_tracking_scaling_policy_configuration {
    target_value       = 60
    scale_out_cooldown = 60
    scale_in_cooldown  = 300

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}

# Tells you when it happens: more tasks than the two it launches with means
# real traffic (or abuse; README, "Unexpected traffic").
resource "aws_cloudwatch_metric_alarm" "scaled_out" {
  alarm_name          = "${var.project}-scaled-out"
  alarm_description   = "The app scaled out past ${var.desired_count} tasks under load. Check the dashboards; scripts/edge.sh top shows who is sending it."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HealthyHostCount"
  dimensions          = local.tg_dimensions
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = var.desired_count
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}
