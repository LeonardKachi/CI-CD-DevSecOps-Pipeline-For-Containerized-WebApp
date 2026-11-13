variable "project" {
  description = "Short project name used in resource names."
  type        = string
}

variable "subnet_id" {
  description = "Private tooling subnet for the Jenkins server."
  type        = string
}

variable "security_group_id" {
  description = "Jenkins security group, from the security module. It has no inbound rules."
  type        = string
}

variable "kms_key_arn" {
  description = "KMS key that encrypts the disk and the stored admin password."
  type        = string
}

variable "ecr_repository_name" {
  description = "ECR repository name. Becomes ECR_REPOSITORY on Jenkins."
  type        = string
}

variable "ecr_repository_arn" {
  description = "ECR repository ARN. Jenkins may push to this repository only."
  type        = string
}

variable "ecs_cluster_name" {
  description = "ECS cluster name. Becomes ECS_CLUSTER on Jenkins."
  type        = string
}

variable "ecs_service_name" {
  description = "ECS service name. Becomes ECS_SERVICE on Jenkins."
  type        = string
}

variable "ecs_service_arn" {
  description = "ECS service ARN. Jenkins may read and update this service only."
  type        = string
}

variable "ecs_task_role_arns" {
  description = "The execution role and task role of the app. These are the only roles Jenkins may hand to ECS."
  type        = list(string)
}

variable "alb_name" {
  description = "Load balancer name. Becomes ALB_NAME on Jenkins, used by the smoke test."
  type        = string
}

variable "github_repo_url" {
  description = "Public Git repository holding the Jenkinsfile. Jenkins only reads it, so no credentials are stored."
  type        = string
  default     = "https://github.com/LeonardKachi/CI-CD-DevSecOps-Pipeline-For-Containerized-WebApp.git"
}

variable "github_token_parameter" {
  description = "For a PRIVATE repository only: name of an SSM SecureString parameter that holds a read-only GitHub token, for example /webapp-2048/github-token. Create it yourself before apply, see the README. Leave empty for a public repository."
  type        = string
  default     = ""

  validation {
    condition     = var.github_token_parameter == "" || startswith(var.github_token_parameter, "/")
    error_message = "The parameter name must start with a slash, for example /webapp-2048/github-token."
  }
}

variable "github_branch" {
  description = "Branch Jenkins watches. Only this branch can deploy."
  type        = string
  default     = "main"
}

variable "instance_type" {
  description = "Server size. Jenkins, Docker builds and the Trivy scan share it, so 4 GiB of memory is a sensible minimum. Must be x86 to match the container architecture."
  type        = string
  default     = "t3.medium"

  validation {
    condition     = !can(regex("^[a-z]+[0-9]+g[a-z]*\\.", var.instance_type))
    error_message = "Use an x86 instance type (not Graviton), so images built here match the X86_64 ECS tasks."
  }
}

variable "root_volume_size" {
  description = "Disk size in GiB. Docker images and the Trivy database need room."
  type        = number
  default     = 30
}

variable "plugin_manager_version" {
  description = "Version of the official Jenkins plugin installer downloaded on first boot."
  type        = string
  default     = "2.16.0"
}

variable "plugin_manager_sha256" {
  description = "SHA-256 checksum of that download. The boot script refuses to run it if the file does not match."
  type        = string
  default     = "b3e9704f8259ec3d0479703039e2ad5a0a15abb97808ad70d5a59ba2fdd73197"
}

variable "jenkins_repo_key_url" {
  description = "Signing key for the Jenkins package repository. Packages are installed only if their signature verifies."
  type        = string
  default     = "https://pkg.jenkins.io/redhat-stable/jenkins.io-2023.key"
}
