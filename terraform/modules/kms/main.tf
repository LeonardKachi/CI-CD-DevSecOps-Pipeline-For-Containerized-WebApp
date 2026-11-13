# KMS module
#
# One customer-managed key for the application stack. It encrypts the ECR
# repository, CloudWatch log groups, the Jenkins disk, and the alarm topic.
# (The Terraform state has its own key, created in the bootstrap folder.)
#
# Why a customer-managed key and not the default AWS keys
#   Every use of the key is recorded in CloudTrail, the key policy decides who
#   can use it, and access can be cut off in one place.
#
# Why this module is separate from the network
#   The network module needs the key (for Flow Logs), and the security groups
#   need the network. Keeping the key on its own avoids a circular dependency.

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

data "aws_iam_policy_document" "key" {
  # Standard statement. It does not give everyone access: it lets IAM policies
  # in this account decide who can use the key. Without it the key could not be
  # managed through IAM and a mistake in this policy could lock everyone out.
  statement {
    sid       = "EnableIamPolicies"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  # CloudWatch Logs can only encrypt a log group with this key if the key policy
  # says so. The condition limits it to log groups in this account and region.
  statement {
    sid    = "AllowCloudWatchLogs"
    effect = "Allow"
    actions = [
      "kms:Encrypt*",
      "kms:Decrypt*",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:Describe*",
    ]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["logs.${data.aws_region.current.region}.amazonaws.com"]
    }

    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:*"]
    }
  }

  # CloudWatch alarms publish to an SNS topic. If the topic is encrypted with
  # this key, the alarm service needs permission to use it. Limited to alarms
  # from this account.
  statement {
    sid    = "AllowCloudWatchAlarms"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey*",
    ]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_kms_key" "this" {
  description             = "Encrypts logs, images, disks and alarms for ${var.project}"
  enable_key_rotation     = true
  deletion_window_in_days = var.deletion_window_in_days
  policy                  = data.aws_iam_policy_document.key.json
}

resource "aws_kms_alias" "this" {
  name          = "alias/${var.project}"
  target_key_id = aws_kms_key.this.key_id
}
