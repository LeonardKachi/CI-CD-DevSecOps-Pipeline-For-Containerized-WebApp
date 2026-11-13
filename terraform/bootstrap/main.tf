# Terraform bootstrap
#
# Creates the S3 bucket that stores the Terraform state of the main stack.
#
# Why this is a separate folder
#   Terraform cannot keep its state in a bucket it has not created yet, so this
#   folder runs once, first, with local state. Everything else then stores its
#   state in the bucket created here.
#
# Why the state is protected so carefully
#   State files describe the whole infrastructure and can contain sensitive
#   values. The bucket is private, encrypted with its own KMS key, versioned,
#   and only reachable over HTTPS.
#
# Why there is no DynamoDB table
#   State locking (stopping two runs from changing state at once) now works
#   natively in S3. DynamoDB locking is deprecated, so this uses one component
#   less. This needs Terraform 1.11 or newer.
#
# Usage
#   terraform init
#   terraform apply
#   Save the "backend_config" output as terraform/backend.hcl. The main stack
#   reads it when it initialises.

terraform {
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

variable "region" {
  description = "AWS region for the state bucket. Use the same region as the main stack."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Short project name used in resource names."
  type        = string
  default     = "webapp-2048"
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = var.project
      Component = "terraform-bootstrap"
      ManagedBy = "terraform"
    }
  }
}

data "aws_caller_identity" "current" {}

locals {
  # The account ID makes the name globally unique and avoids guessable names.
  bucket_name = "${var.project}-tfstate-${data.aws_caller_identity.current.account_id}"
}

# --- Encryption key -------------------------------------------------------
# A dedicated customer-managed key, so every use of the state is auditable in
# CloudTrail and access can be revoked separately from the bucket.

resource "aws_kms_key" "state" {
  description             = "Encrypts the Terraform state of ${var.project}"
  enable_key_rotation     = true
  deletion_window_in_days = 30
}

resource "aws_kms_alias" "state" {
  name          = "alias/${var.project}-tfstate"
  target_key_id = aws_kms_key.state.key_id
}

# --- State bucket ---------------------------------------------------------

resource "aws_s3_bucket" "state" {
  bucket = local.bucket_name

  # Losing this bucket means losing track of everything Terraform built.
  # To remove it on purpose, delete this block first.
  lifecycle {
    prevent_destroy = true
  }
}

# Turns off ACLs, so access is controlled only by IAM and the bucket policy.
resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# All four settings on: the bucket can never be made public, even by mistake.
resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Every change keeps the previous version, so a bad apply or an accidental
# delete can be undone.
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.state.arn
    }
    # Fewer KMS requests, so lower cost, with the same protection.
    bucket_key_enabled = true
  }
}

# Old versions are kept for 90 days, which is plenty for recovery, then removed.
resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.state]
}

# Refuse any request that is not encrypted in transit.
data "aws_iam_policy_document" "state" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]

    resources = [
      aws_s3_bucket.state.arn,
      "${aws_s3_bucket.state.arn}/*",
    ]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state.json

  depends_on = [aws_s3_bucket_public_access_block.state]
}

# --- Outputs --------------------------------------------------------------

output "state_bucket" {
  description = "Name of the state bucket."
  value       = aws_s3_bucket.state.id
}

output "kms_key_arn" {
  description = "ARN of the key that encrypts the state."
  value       = aws_kms_key.state.arn
}

# The main stack keeps its bucket details in a file that is not committed,
# because the bucket name contains the account ID. This output prints that file.
output "backend_config" {
  description = "Save this as terraform/backend.hcl, then run: terraform init -backend-config=backend.hcl"
  value       = <<-EOT
    bucket       = "${aws_s3_bucket.state.id}"
    key          = "${var.project}/terraform.tfstate"
    region       = "${var.region}"
    encrypt      = true
    kms_key_id   = "${aws_kms_key.state.arn}"
    use_lockfile = true
  EOT
}
