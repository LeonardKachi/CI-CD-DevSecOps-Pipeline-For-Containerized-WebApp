# Jenkins module
#
# The CI/CD server: one EC2 instance in the private tooling subnet, built
# entirely by Terraform and configured on first boot, so nobody clicks through
# a setup wizard and the whole server can be rebuilt from this code.
#
# How it is locked down
#   - no public IP and no inbound rules (see the security module)
#   - reached only through SSM Session Manager port forwarding, never SSH
#   - Jenkins listens on 127.0.0.1 only, as a second barrier behind the firewall
#   - no AWS keys: the instance role is the only credential, scoped to this one
#     repository, this one service, and nothing else
#   - metadata service v2 only, with a hop limit of 1, so a container running on
#     the server cannot reach the role credentials
#   - encrypted disk, and the admin password generated on the server itself and
#     stored encrypted in SSM Parameter Store, never in Git or Terraform state

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  region     = data.aws_region.current.region
  account_id = data.aws_caller_identity.current.account_id

  admin_password_parameter = "/${var.project}/jenkins/admin-password"
  admin_password_arn       = "arn:aws:ssm:${local.region}:${local.account_id}:parameter${local.admin_password_parameter}"
}

# Always the current, patched Amazon Linux 2023 image. AWS publishes the newest
# image ID under this public parameter.
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

# --- IAM role ---------------------------------------------------------------

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "jenkins" {
  name               = "${var.project}-jenkins"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

# Lets Session Manager reach the server. This is the standard AWS-managed policy.
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.jenkins.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Exactly the AWS calls the Jenkinsfile makes, and no more.
data "aws_iam_policy_document" "pipeline" {
  # A registry login token cannot be limited to one repository.
  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "PushToTheAppRepositoryOnly"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      "ecr:DescribeImages",
    ]
    resources = [var.ecr_repository_arn]
  }

  statement {
    sid       = "DeployTheOneService"
    actions   = ["ecs:DescribeServices", "ecs:UpdateService"]
    resources = [var.ecs_service_arn]
  }

  # AWS does not allow task definition actions to be limited to one resource.
  # The PassRole statement below is what keeps this safe.
  statement {
    sid       = "TaskDefinitionsHaveNoResourceLevelControl"
    actions   = ["ecs:DescribeTaskDefinition", "ecs:RegisterTaskDefinition"]
    resources = ["*"]
  }

  # Registering a task definition names the roles it will use. Jenkins may name
  # only the app's two roles, and only for ECS tasks. It cannot register a task
  # that runs with a more powerful role.
  statement {
    sid       = "PassOnlyTheAppRolesToEcs"
    actions   = ["iam:PassRole"]
    resources = var.ecs_task_role_arns

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }

  # Describe calls for load balancers cannot be limited to one resource.
  statement {
    sid       = "FindTheLoadBalancerForTheSmokeTest"
    actions   = ["elasticloadbalancing:DescribeLoadBalancers"]
    resources = ["*"]
  }

  # Private repository only: on first boot the server reads the read-only GitHub
  # token from this one parameter. Parameters created with the default AWS key
  # can be read by any principal that is allowed to call SSM, so no separate key
  # permission is needed.
  dynamic "statement" {
    for_each = var.github_token_parameter != "" ? [1] : []

    content {
      sid       = "ReadTheGithubTokenOnBoot"
      actions   = ["ssm:GetParameter"]
      resources = ["arn:aws:ssm:${local.region}:${local.account_id}:parameter${var.github_token_parameter}"]
    }
  }

  # On first boot the server stores the admin password it generated. It may write
  # that one parameter, using the project key only through SSM.
  statement {
    sid       = "StoreTheGeneratedAdminPassword"
    actions   = ["ssm:PutParameter"]
    resources = [local.admin_password_arn]
  }

  statement {
    sid = "UseTheProjectKeyThroughSsmOnly"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:GenerateDataKey",
      "kms:DescribeKey",
    ]
    resources = [var.kms_key_arn]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${local.region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "pipeline" {
  name   = "pipeline-permissions"
  role   = aws_iam_role.jenkins.id
  policy = data.aws_iam_policy_document.pipeline.json
}

resource "aws_iam_instance_profile" "jenkins" {
  name = "${var.project}-jenkins"
  role = aws_iam_role.jenkins.name
}

# --- Server -----------------------------------------------------------------

resource "aws_instance" "jenkins" {
  ami                         = data.aws_ssm_parameter.al2023.insecure_value
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [var.security_group_id]
  iam_instance_profile        = aws_iam_instance_profile.jenkins.name
  associate_public_ip_address = false

  # Metadata service v2 only. Version 1 can be abused by a request-forgery bug
  # to steal the role credentials. A hop limit of 1 also keeps the metadata
  # service out of reach of containers running on this server, such as the lint
  # and scan containers started by the pipeline.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size
    encrypted             = true
    kms_key_id            = var.kms_key_arn
    delete_on_termination = true
  }

  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    region                   = local.region
    project                  = var.project
    ecr_repository_name      = var.ecr_repository_name
    ecs_cluster_name         = var.ecs_cluster_name
    ecs_service_name         = var.ecs_service_name
    alb_name                 = var.alb_name
    github_repo_url          = var.github_repo_url
    github_branch            = var.github_branch
    github_token_parameter   = var.github_token_parameter
    kms_key_arn              = var.kms_key_arn
    admin_password_parameter = local.admin_password_parameter
    plugin_manager_version   = var.plugin_manager_version
    plugin_manager_sha256    = var.plugin_manager_sha256
    jenkins_repo_key_url     = var.jenkins_repo_key_url
  })

  # The boot script runs once. A later change to it does not rebuild the server
  # and does not re-run, so changes to a running server are made by rebuilding
  # it on purpose (terraform apply -replace).
  user_data_replace_on_change = false

  tags = {
    Name = "${var.project}-jenkins"
  }

  lifecycle {
    # A newer image is published every few weeks. Without this, Terraform would
    # replace the server, and its job history, the next time it ran.
    ignore_changes = [ami]
  }

  depends_on = [
    aws_iam_role_policy.pipeline,
    aws_iam_role_policy_attachment.ssm,
  ]
}
