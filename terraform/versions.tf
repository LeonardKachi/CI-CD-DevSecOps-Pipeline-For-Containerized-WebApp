terraform {
  # S3 native state locking (used by the backend below) needs Terraform 1.11.
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # State is stored in the encrypted bucket created by the bootstrap folder.
  # A backend block cannot use variables, and the bucket name contains your
  # account ID, so the details stay out of Git and are passed when initialising:
  #
  #   terraform init -backend-config=backend.hcl
  #
  # The bootstrap step prints the exact contents for backend.hcl.
  backend "s3" {}
}
