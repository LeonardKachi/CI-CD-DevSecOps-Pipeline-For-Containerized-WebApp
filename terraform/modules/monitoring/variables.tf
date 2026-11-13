variable "project" {
  description = "Short project name used in resource names."
  type        = string
}

variable "kms_key_arn" {
  description = "KMS key that encrypts the alarm topic."
  type        = string
}

variable "alert_email" {
  description = "Address that receives alarm emails. AWS sends a confirmation link first, and nothing is delivered until it is clicked."
  type        = string

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.alert_email))
    error_message = "alert_email must be a valid email address."
  }
}

variable "alb_arn_suffix" {
  description = "Load balancer identifier for CloudWatch metrics, from the alb module."
  type        = string
}

variable "target_group_arn_suffix" {
  description = "Target group identifier for CloudWatch metrics, from the alb module."
  type        = string
}

variable "cluster_name" {
  description = "ECS cluster name, from the ecs module."
  type        = string
}

variable "service_name" {
  description = "ECS service name, from the ecs module."
  type        = string
}

variable "log_group_name" {
  description = "CloudWatch log group of the application, from the ecs module."
  type        = string
}

variable "error_5xx_threshold" {
  description = "Alarm when the site returns more than this many server errors per minute, in 3 of 5 minutes."
  type        = number
  default     = 5
}

variable "cpu_alarm_threshold" {
  description = "Alarm when average CPU stays above this percentage. Auto scaling aims for 60, so 80 means scaling is not keeping up."
  type        = number
  default     = 80
}

variable "memory_alarm_threshold" {
  description = "Alarm when average memory stays above this percentage."
  type        = number
  default     = 80
}
