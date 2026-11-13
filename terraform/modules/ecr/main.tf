# ECR module
#
# The private registry where the pipeline stores the container image.
#
# The aim is that an image in this repository can be trusted:
#   - tags are immutable, so a released version can never be silently replaced
#   - images are scanned on push and encrypted with the project key
#   - only the pipeline can push, and only the running service can pull
#   - old images are cleaned up, but enough are kept to roll back to

resource "aws_ecr_repository" "this" {
  name                 = var.repository_name
  image_tag_mutability = "IMMUTABLE"
  force_delete         = var.force_delete

  # Each image is tagged with its commit. With immutable tags, a tag always
  # means the same bytes, so "what is running" can always be traced to a commit.

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = var.kms_key_arn
  }
}

# Keeps the repository small and cheap without losing the ability to roll back.
resource "aws_ecr_lifecycle_policy" "this" {
  repository = aws_ecr_repository.this.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Remove untagged images (failed or interrupted pushes) after 1 day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep only the newest ${var.max_image_count} images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = var.max_image_count
        }
        action = { type = "expire" }
      },
    ]
  })
}

# Who may push and pull.
#
# IAM already limits this from the role side. This repository policy adds a
# second lock from the repository side: even a person or role in the account
# with broad ECR permissions cannot push an image or pull one unless they are
# on the list. Both statements are explicit denies, and a deny always wins.
#
# Management actions (reading the repository, changing or deleting this policy)
# are not denied, so an administrator can never be locked out.
#
# The policy is created only when both lists are filled in, so the repository
# can be built first and locked down once the roles exist.
data "aws_iam_policy_document" "repository" {
  count = length(var.push_principal_arns) > 0 && length(var.pull_principal_arns) > 0 ? 1 : 0

  statement {
    sid    = "OnlyThePipelineCanPush"
    effect = "Deny"
    actions = [
      "ecr:PutImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
    ]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    # With a "not equals" test, the deny applies when the caller matches none of
    # the listed roles.
    condition {
      test     = "ArnNotEquals"
      variable = "aws:PrincipalArn"
      values   = var.push_principal_arns
    }
  }

  statement {
    sid    = "OnlyThePipelineAndTheServiceCanPull"
    effect = "Deny"
    actions = [
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
    ]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "ArnNotEquals"
      variable = "aws:PrincipalArn"
      values   = distinct(concat(var.pull_principal_arns, var.push_principal_arns))
    }
  }
}

resource "aws_ecr_repository_policy" "this" {
  count = length(data.aws_iam_policy_document.repository)

  repository = aws_ecr_repository.this.name
  policy     = data.aws_iam_policy_document.repository[0].json
}
