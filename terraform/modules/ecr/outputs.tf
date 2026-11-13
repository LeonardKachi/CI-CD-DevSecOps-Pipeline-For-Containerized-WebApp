output "repository_name" {
  description = "Repository name. Set as ECR_REPOSITORY on the Jenkins controller."
  value       = aws_ecr_repository.this.name
}

output "repository_url" {
  description = "Full repository address, used by the ECS task definition."
  value       = aws_ecr_repository.this.repository_url
}

output "repository_arn" {
  description = "Repository ARN, used to scope IAM permissions to this one repository."
  value       = aws_ecr_repository.this.arn
}
