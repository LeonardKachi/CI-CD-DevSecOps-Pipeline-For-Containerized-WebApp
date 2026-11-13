variable "repository_name" {
  description = "Name of the ECR repository. The Jenkins pipeline reads it from the ECR_REPOSITORY variable."
  type        = string
  default     = "webapp-2048"
}

variable "kms_key_arn" {
  description = "KMS key that encrypts the images at rest."
  type        = string
}

variable "max_image_count" {
  description = "How many of the newest images to keep. Older ones are deleted."
  type        = number
  default     = 10

  validation {
    condition     = var.max_image_count >= 3
    error_message = "Keep at least 3 images so there is always something to roll back to."
  }
}

variable "force_delete" {
  description = "Let Terraform delete the repository even if it still holds images. Leave false in real use, set true to clean up after the challenge."
  type        = bool
  default     = false
}

variable "push_principal_arns" {
  description = "IAM roles allowed to push images. Everyone else is denied. Pass the Jenkins role."
  type        = list(string)
  default     = []
}

variable "pull_principal_arns" {
  description = "IAM roles allowed to pull images. Everyone else is denied. Pass the ECS task execution role."
  type        = list(string)
  default     = []
}
