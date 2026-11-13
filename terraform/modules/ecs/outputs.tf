output "cluster_name" {
  description = "Cluster name. Set as ECS_CLUSTER on the Jenkins controller."
  value       = aws_ecs_cluster.this.name
}

output "service_name" {
  description = "Service name. Set as ECS_SERVICE on the Jenkins controller."
  value       = aws_ecs_service.app.name
}

output "cluster_arn" {
  description = "Cluster ARN, used to limit the Jenkins role to this cluster."
  value       = aws_ecs_cluster.this.arn
}

output "service_arn" {
  description = "Service ARN, used to limit the Jenkins role to this one service."
  value       = aws_ecs_service.app.id
}

output "task_family" {
  description = "Task definition family. The Jenkins role may register revisions of this family only."
  value       = aws_ecs_task_definition.app.family
}

output "execution_role_arn" {
  description = "Task execution role. Jenkins may pass it to ECS, and it is the role allowed to pull from ECR."
  value       = aws_iam_role.execution.arn
}

output "task_role_arn" {
  description = "Task role. Jenkins may pass it to ECS."
  value       = aws_iam_role.task.arn
}

output "log_group_name" {
  description = "CloudWatch log group of the application."
  value       = aws_cloudwatch_log_group.app.name
}

output "log_group_arn" {
  description = "ARN of the application log group."
  value       = aws_cloudwatch_log_group.app.arn
}
