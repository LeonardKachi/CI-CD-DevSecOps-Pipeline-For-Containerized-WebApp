variable "project" {
  description = "Short project name, used in the key alias."
  type        = string
}

variable "deletion_window_in_days" {
  description = "Days the key waits before deletion after it is scheduled for removal."
  type        = number
  default     = 30

  validation {
    condition     = var.deletion_window_in_days >= 7 && var.deletion_window_in_days <= 30
    error_message = "KMS only allows a deletion window between 7 and 30 days."
  }
}
