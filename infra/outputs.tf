output "app_url" {
  description = "Public URL of the app."
  value       = "http://${aws_lb.this.dns_name}"
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
  description = "Image currently deployed."
  value       = "${data.aws_ecr_repository.app.repository_url}:${var.image_tag}"
}
