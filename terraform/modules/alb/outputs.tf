output "alb_name" {
  description = "Load balancer name. Set as ALB_NAME on the Jenkins controller, the smoke test uses it."
  value       = aws_lb.this.name
}

output "alb_dns_name" {
  description = "Public address of the application."
  value       = aws_lb.this.dns_name
}

output "alb_arn" {
  description = "Load balancer ARN."
  value       = aws_lb.this.arn
}

output "alb_arn_suffix" {
  description = "Load balancer identifier used in CloudWatch metrics and alarms."
  value       = aws_lb.this.arn_suffix
}

output "target_group_arn" {
  description = "Target group the ECS service registers its tasks in."
  value       = aws_lb_target_group.app.arn
}

output "target_group_arn_suffix" {
  description = "Target group identifier used in CloudWatch metrics and alarms."
  value       = aws_lb_target_group.app.arn_suffix
}

output "listener_arn" {
  description = "ARN of the HTTP listener. The ECS service waits for it to exist."
  value       = aws_lb_listener.http.arn
}

output "access_log_bucket" {
  description = "Bucket holding the load balancer access logs."
  value       = aws_s3_bucket.logs.id
}
