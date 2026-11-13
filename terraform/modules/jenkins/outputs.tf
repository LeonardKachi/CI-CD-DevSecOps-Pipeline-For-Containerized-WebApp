output "instance_id" {
  description = "ID of the Jenkins server."
  value       = aws_instance.jenkins.id
}

output "role_arn" {
  description = "Jenkins role. Pass it to the ECR module as the only principal allowed to push."
  value       = aws_iam_role.jenkins.arn
}

output "admin_password_parameter" {
  description = "SSM parameter holding the generated Jenkins admin password."
  value       = local.admin_password_parameter
}

output "get_admin_password_command" {
  description = "Run this to read the Jenkins admin password. It needs your own AWS permissions."
  value       = "aws ssm get-parameter --name ${local.admin_password_parameter} --with-decryption --query Parameter.Value --output text --region ${local.region}"
}

output "open_jenkins_command" {
  description = "Run this, then browse to http://localhost:8080. Jenkins has no public address, so this tunnel through Session Manager is the only way in."
  value       = "aws ssm start-session --target ${aws_instance.jenkins.id} --document-name AWS-StartPortForwardingSession --parameters '{\"portNumber\":[\"8080\"],\"localPortNumber\":[\"8080\"]}' --region ${local.region}"
}

output "shell_command" {
  description = "Run this for a shell on the server, for troubleshooting. Boot log: /var/log/jenkins-bootstrap.log"
  value       = "aws ssm start-session --target ${aws_instance.jenkins.id} --region ${local.region}"
}
