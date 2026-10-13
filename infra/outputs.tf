output "app_url" {
  description = "Public URL of the app."
  value       = "https://${aws_route53_record.app.fqdn}"
}

output "grafana_url" {
  description = "Public URL of the Grafana dashboards."
  value       = "https://${aws_route53_record.grafana.fqdn}"
}

output "cluster_name" {
  description = "ECS cluster name."
  value       = aws_ecs_cluster.this.name
}

output "service_name" {
  description = "ECS service name."
  value       = aws_ecs_service.app.name
}

output "log_group" {
  description = "CloudWatch Logs group for the app."
  value       = aws_cloudwatch_log_group.app.name
}

output "image" {
  description = "App image currently deployed."
  value       = "${data.aws_ecr_repository.app.repository_url}:${var.image_tag}"
}

output "obs_config_image" {
  description = "Observability config image currently deployed."
  value       = "${data.aws_ecr_repository.obs_config.repository_url}:${var.obs_config_tag}"
}
