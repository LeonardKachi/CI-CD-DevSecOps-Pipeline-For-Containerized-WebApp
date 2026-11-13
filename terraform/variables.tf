variable "region" {
  description = "AWS region for everything. Use the same region as the bootstrap step."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Short project name used in resource names. 24 characters or fewer."
  type        = string
  default     = "webapp-2048"
}

variable "alert_email" {
  description = "Your email address for alarm notifications. Required, with no default, so Terraform asks for it. AWS sends a confirmation link to it, and alarms are delivered only after you click it."
  type        = string

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.alert_email))
    error_message = "alert_email must be a valid email address."
  }

  # Stops the placeholder from the example file being used by accident.
  validation {
    condition     = !endswith(lower(var.alert_email), "@example.com") && !endswith(lower(var.alert_email), "@example.org")
    error_message = "That looks like a placeholder address. Use your real email address, or no alarm will ever reach you."
  }
}

variable "github_repo_url" {
  description = "Public Git repository that holds the Jenkinsfile."
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

variable "allow_teardown" {
  description = "True lets terraform destroy remove everything, including the container images and logs, and shortens the key deletion wait. False is the safe setting for real use: it keeps images and logs and turns on load balancer deletion protection."
  type        = bool
  default     = true
}

variable "alb_ingress_cidrs" {
  description = "Who may reach the site. Open to the internet by default. Set to your own IP range such as [\"203.0.113.7/32\"] to lock the site down."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "min_capacity" {
  description = "Fewest app tasks. 2 keeps one in each Availability Zone."
  type        = number
  default     = 2
}

variable "max_capacity" {
  description = "Most app tasks auto scaling may start. This is the cost ceiling."
  type        = number
  default     = 6
}

variable "jenkins_instance_type" {
  description = "Size of the Jenkins server. Must be x86."
  type        = string
  default     = "t3.medium"
}
