variable "project" {
  description = "Short project name used in resource names. Load balancer names are limited to 32 characters."
  type        = string

  validation {
    condition     = length(var.project) <= 24
    error_message = "Keep the project name to 24 characters or fewer, so the load balancer name stays within the 32 character limit."
  }
}

variable "vpc_id" {
  description = "VPC that holds the load balancer and its targets."
  type        = string
}

variable "public_subnet_ids" {
  description = "Public subnets (one per Availability Zone) for the load balancer."
  type        = list(string)
}

variable "alb_security_group_id" {
  description = "Security group of the load balancer, from the security module."
  type        = string
}

variable "listener_port" {
  description = "Port the load balancer listens on. Must match the security group."
  type        = number
  default     = 80
}

variable "target_port" {
  description = "Port the app containers listen on. Must match the Dockerfile and nginx.conf."
  type        = number
  default     = 8080
}

variable "health_check_path" {
  description = "Path the load balancer calls to decide if a task is healthy. Served by nginx.conf."
  type        = string
  default     = "/health"
}

variable "idle_timeout" {
  description = "Seconds an idle connection stays open. Nginx keepalive_timeout must be longer than this."
  type        = number
  default     = 60
}

variable "enable_deletion_protection" {
  description = "Block accidental deletion of the load balancer. Turn on for real use, leave off so the challenge can be cleaned up."
  type        = bool
  default     = false
}

variable "access_log_retention_days" {
  description = "How long load balancer access logs are kept before they are deleted."
  type        = number
  default     = 90
}

variable "force_destroy_log_bucket" {
  description = "Let Terraform delete the access log bucket even if it holds logs. Set true to clean up after the challenge."
  type        = bool
  default     = false
}

variable "use_regional_elb_account" {
  description = "Older regions deliver access logs through a regional AWS account. Set false only in regions opened after August 2022, which use a service principal instead."
  type        = bool
  default     = true
}
