output "app_url" {
  description = "Public address of the game. It returns 503 until the first pipeline run has deployed an image."
  value       = "http://${module.alb.alb_dns_name}"
}

output "dashboard_url" {
  description = "CloudWatch dashboard for the whole system."
  value       = module.monitoring.dashboard_url
}

output "ecr_repository_url" {
  description = "Where the pipeline stores the container images."
  value       = module.ecr.repository_url
}

output "nat_public_ip" {
  description = "The one public IP all outbound traffic from private subnets uses."
  value       = module.network.nat_public_ip
}

output "region" {
  description = "AWS region everything was built in."
  value       = var.region
}

output "jenkins_admin_password_parameter" {
  description = "SSM parameter that holds the Jenkins admin password."
  value       = module.jenkins.admin_password_parameter
}

output "jenkins_instance_id" {
  description = "ID of the Jenkins server."
  value       = module.jenkins.instance_id
}

output "jenkins_open_command" {
  description = "Opens a tunnel to Jenkins. Then browse to http://localhost:8080 and log in as admin."
  value       = module.jenkins.open_jenkins_command
}

output "jenkins_password_command" {
  description = "Prints the Jenkins admin password."
  value       = module.jenkins.get_admin_password_command
}

output "jenkins_shell_command" {
  description = "Shell on the Jenkins server, for troubleshooting only."
  value       = module.jenkins.shell_command
}

output "next_steps" {
  description = "What to do after terraform apply finishes."
  value       = <<-EOT
    0. Jenkins builds from ${var.github_repo_url} (branch ${var.github_branch}), not from your computer.
       If this project is not pushed there, Jenkins finds no Jenkinsfile and nothing is ever built.
       A private repository also needs the read-only token (see the README).
       Check with: bash scripts/preflight.sh
    1. Open your email and click the AWS confirmation link, or no alarm will reach you.
    2. Wait about 10 minutes for Jenkins to finish its first-boot setup.
    3. Run: bash scripts/jenkins.sh tunnel      then browse to http://localhost:8080 and log in as admin.
       Run: bash scripts/jenkins.sh password    to print the admin password.
    4. Jenkins checks GitHub every 2 minutes and starts the first build by itself.
       The first build pushes the image and deploys it.
       If nothing seems to happen, run: bash scripts/jenkins.sh doctor
    5. When the build finishes, open the app_url output.
  EOT
}
