variable "project" {
  description = "Short project name used in resource names."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private app subnets (one per Availability Zone) where the tasks run."
  type        = list(string)
}

variable "app_security_group_id" {
  description = "Security group of the tasks, from the security module."
  type        = string
}

variable "target_group_arn" {
  description = "Load balancer target group the tasks register in."
  type        = string
}

variable "alb_arn_suffix" {
  description = "Load balancer identifier, used by the request-count scaling policy."
  type        = string
}

variable "target_group_arn_suffix" {
  description = "Target group identifier, used by the request-count scaling policy."
  type        = string
}

variable "repository_url" {
  description = "ECR repository address, without a tag."
  type        = string
}

variable "repository_arn" {
  description = "ECR repository ARN. The execution role may pull from this repository only."
  type        = string
}

variable "kms_key_arn" {
  description = "KMS key that encrypts the log group."
  type        = string
}

variable "container_name" {
  description = "Name of the application container inside the task."
  type        = string
  default     = "webapp"
}

variable "container_port" {
  description = "Port the application listens on. Must match the Dockerfile and nginx.conf."
  type        = number
  default     = 8080
}

variable "initial_image_tag" {
  description = "Tag of the placeholder image in the first task definition. It does not exist yet, so the service cannot start tasks until the first pipeline run. That is expected."
  type        = string
  default     = "initial"
}

variable "cpu" {
  description = "Task CPU units. 256 is a quarter of a vCPU, plenty for a static site."
  type        = number
  default     = 256
}

variable "memory" {
  description = "Task memory in MiB. Must be a valid pair with the CPU value."
  type        = number
  default     = 512
}

variable "cpu_architecture" {
  description = "Must match the architecture the Jenkins server builds images for."
  type        = string
  default     = "X86_64"

  validation {
    condition     = contains(["X86_64", "ARM64"], var.cpu_architecture)
    error_message = "cpu_architecture must be X86_64 or ARM64."
  }
}

variable "min_capacity" {
  description = "Fewest tasks to run. 2 keeps one task in each Availability Zone."
  type        = number
  default     = 2
}

variable "max_capacity" {
  description = "Most tasks auto scaling may start. This caps cost if traffic spikes or someone floods the site."
  type        = number
  default     = 6

  validation {
    condition     = var.max_capacity >= 2
    error_message = "max_capacity must be at least 2."
  }
}

variable "requests_per_target" {
  description = "Scale out when each task averages more than this many requests per minute."
  type        = number
  default     = 1000
}

variable "cpu_target_percent" {
  description = "Scale out when average CPU across tasks goes above this percentage."
  type        = number
  default     = 60
}

variable "log_retention_days" {
  description = "How long container logs are kept in CloudWatch."
  type        = number
  default     = 30

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_days)
    error_message = "CloudWatch only accepts specific retention values, for example 7, 14, 30, 60 or 90."
  }
}

variable "enable_container_insights" {
  description = "Detailed per-container metrics. Costs extra, so off by default. Basic CPU and memory metrics are always available."
  type        = bool
  default     = false
}
