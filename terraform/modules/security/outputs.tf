output "alb_security_group_id" {
  description = "Security group for the load balancer."
  value       = aws_security_group.alb.id
}

output "app_security_group_id" {
  description = "Security group for the application tasks."
  value       = aws_security_group.app.id
}

output "jenkins_security_group_id" {
  description = "Security group for the Jenkins server."
  value       = aws_security_group.jenkins.id
}
