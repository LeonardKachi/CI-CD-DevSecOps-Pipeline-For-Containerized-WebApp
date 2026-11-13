variable "project" {
  description = "Short project name used in resource names."
  type        = string
}

variable "kms_key_arn" {
  description = "KMS key that encrypts the VPC Flow Logs log group."
  type        = string
}

variable "vpc_cidr" {
  description = "IP range of the whole VPC."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid CIDR block, for example 10.0.0.0/16."
  }
}

variable "public_subnet_cidrs" {
  description = "Two public subnets, one per Availability Zone. They hold only the load balancer and the NAT gateway."
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]

  validation {
    condition     = length(var.public_subnet_cidrs) == 2
    error_message = "Exactly two public subnets are required (one per Availability Zone)."
  }
}

variable "private_app_subnet_cidrs" {
  description = "Two private subnets for the application containers, one per Availability Zone."
  type        = list(string)
  default     = ["10.0.11.0/24", "10.0.12.0/24"]

  validation {
    condition     = length(var.private_app_subnet_cidrs) == 2
    error_message = "Exactly two private app subnets are required (one per Availability Zone)."
  }
}

variable "private_tooling_subnet_cidr" {
  description = "Private subnet for the Jenkins server, kept apart from the application subnets."
  type        = string
  default     = "10.0.21.0/24"
}

variable "flow_log_retention_days" {
  description = "How long VPC Flow Logs are kept in CloudWatch."
  type        = number
  default     = 30

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.flow_log_retention_days)
    error_message = "CloudWatch only accepts specific retention values, for example 7, 14, 30, 60 or 90."
  }
}
