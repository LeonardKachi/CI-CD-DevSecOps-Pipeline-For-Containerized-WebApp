# ECS module
#
# Runs the application on Fargate: the cluster, the task definition (how the
# container runs), the service (keeps the right number of tasks running and
# registered with the load balancer), the two IAM roles, the log group, and
# auto scaling.
#
# Who changes what
#   Terraform builds all of this once. After that, the Jenkins pipeline deploys
#   new versions by registering a new task definition revision with a new image
#   and pointing the service at it. That is why the service ignores changes to
#   its task definition and desired count: otherwise the next "terraform apply"
#   would undo the last deployment and the last scaling decision.

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  region     = data.aws_region.current.region
  account_id = data.aws_caller_identity.current.account_id
  image      = "${var.repository_url}:${var.initial_image_tag}"

  log_options = {
    "awslogs-group"  = aws_cloudwatch_log_group.app.name
    "awslogs-region" = local.region
  }
}

# --- Cluster ----------------------------------------------------------------
# ECS Exec (a shell inside a running container) is not enabled anywhere in this
# stack. Nobody can open a session into a running task.

resource "aws_ecs_cluster" "this" {
  name = "${var.project}-cluster"

  setting {
    name  = "containerInsights"
    value = var.enable_container_insights ? "enabled" : "disabled"
  }
}

# --- Logs -------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${var.project}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
}

# --- IAM roles --------------------------------------------------------------
# Two roles with two different jobs, kept apart on purpose:
#   execution role  used by ECS itself to start the task (pull image, write logs)
#   task role       used by the application code. The game calls no AWS
#                   service, so it has no permissions at all.

# Only the ECS tasks service, acting for this account, can use these roles. This
# stops another account's tasks from being tricked into using them.
data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:ecs:${local.region}:${local.account_id}:*"]
    }
  }
}

resource "aws_iam_role" "execution" {
  name               = "${var.project}-ecs-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

data "aws_iam_policy_document" "execution" {
  # Fetching a registry login token cannot be limited to one repository.
  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  # Pull from this one repository only.
  statement {
    sid = "PullTheAppImage"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = [var.repository_arn]
  }

  # Write to this one log group only.
  statement {
    sid       = "WriteContainerLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.app.arn}:*"]
  }
}

resource "aws_iam_role_policy" "execution" {
  name   = "start-the-task"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution.json
}

# No policy is attached. If the container is ever compromised, the stolen role
# can do nothing in AWS.
resource "aws_iam_role" "task" {
  name               = "${var.project}-ecs-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

# --- Task definition --------------------------------------------------------

resource "aws_ecs_task_definition" "app" {
  family                   = "${var.project}-app"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = var.cpu_architecture
  }

  # Writable scratch space for Nginx (its pid file and temporary files). The
  # rest of the container filesystem is read-only.
  volume {
    name = "tmp"
  }

  container_definitions = jsonencode([
    {
      name      = var.container_name
      image     = local.image
      essential = true

      # Non-root, enforced here as well as in the Dockerfile. Even if a future
      # image forgot to set a user, the task would still not run as root.
      user = "101"

      # The container cannot change its own files, so an attacker who gets in
      # cannot plant or modify anything in the image.
      readonlyRootFilesystem = true

      linuxParameters = {
        # No Linux capabilities at all. Nginx on a high port needs none.
        capabilities       = { drop = ["ALL"] }
        initProcessEnabled = true
      }

      portMappings = [{
        containerPort = var.container_port
        protocol      = "tcp"
      }]

      mountPoints = [{
        sourceVolume  = "tmp"
        containerPath = "/tmp"
        readOnly      = false
      }]

      # Starts only after the scratch folder has been prepared.
      dependsOn = [{
        containerName = "init-tmp"
        condition     = "SUCCESS"
      }]

      # Same check as the Dockerfile HEALTHCHECK and the load balancer.
      healthCheck = {
        command     = ["CMD-SHELL", "wget -q -O /dev/null http://127.0.0.1:${var.container_port}/health || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 10
      }

      logConfiguration = {
        logDriver = "awslogs"
        options   = merge(local.log_options, { "awslogs-stream-prefix" = "app" })
      }
    },

    # A new Fargate volume starts out owned by root, and the app runs as a
    # normal user, so it could not write to it. This tiny helper runs once as
    # root, opens up the folder, and exits. It uses the same image, so nothing
    # extra is downloaded and the pipeline updates it together with the app.
    {
      name      = "init-tmp"
      image     = local.image
      essential = false
      user      = "0"

      readonlyRootFilesystem = true
      entryPoint             = ["sh", "-c"]
      command                = ["chmod 1777 /tmp"]

      linuxParameters = {
        capabilities = { drop = ["ALL"] }
      }

      mountPoints = [{
        sourceVolume  = "tmp"
        containerPath = "/tmp"
        readOnly      = false
      }]

      logConfiguration = {
        logDriver = "awslogs"
        options   = merge(local.log_options, { "awslogs-stream-prefix" = "init" })
      }
    },
  ])

  # Keep old revisions. Rolling back needs the previous revision to still exist.
  skip_destroy = true
}

# --- Service ----------------------------------------------------------------

resource "aws_ecs_service" "app" {
  name            = "${var.project}-service"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = var.min_capacity
  launch_type     = "FARGATE"

  # Tasks get private addresses only and no shell access.
  enable_execute_command = false

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [var.app_security_group_id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = var.target_group_arn
    container_name   = var.container_name
    container_port   = var.container_port
  }

  # A deployment starts new tasks first and only removes old ones once the new
  # ones are healthy, so users never see a gap. This needs room for up to twice
  # the running tasks for a few minutes.
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  # If new tasks keep failing, ECS stops the deployment and goes back to the
  # last working version by itself.
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  # Gives a new task time to start before the load balancer judges it.
  health_check_grace_period_seconds = 30

  lifecycle {
    # The pipeline owns the task definition, auto scaling owns the count.
    ignore_changes = [task_definition, desired_count]
  }

  # The target group must already be attached to a listener. The root module
  # makes this module wait for the ALB module.
}

# --- Auto scaling -----------------------------------------------------------
# Fargate removes the servers, but not the decision of how many tasks to run.
# That decision is made here: between a minimum of 2 (one per Availability
# Zone, so the app survives losing one) and a maximum of 6 (a cost ceiling, so
# a traffic flood or attack cannot scale into a huge bill).

resource "aws_appautoscaling_target" "app" {
  service_namespace  = "ecs"
  scalable_dimension = "ecs:service:DesiredCount"
  resource_id        = "service/${aws_ecs_cluster.this.name}/${aws_ecs_service.app.name}"
  min_capacity       = var.min_capacity
  max_capacity       = var.max_capacity
}

# Main signal: requests per task. A static Nginx site uses very little CPU, so
# CPU alone would react too late.
resource "aws_appautoscaling_policy" "requests" {
  name               = "${var.project}-requests-per-task"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.app.service_namespace
  scalable_dimension = aws_appautoscaling_target.app.scalable_dimension
  resource_id        = aws_appautoscaling_target.app.resource_id

  target_tracking_scaling_policy_configuration {
    target_value = var.requests_per_target

    predefined_metric_specification {
      predefined_metric_type = "ALBRequestCountPerTarget"
      resource_label         = "${var.alb_arn_suffix}/${var.target_group_arn_suffix}"
    }

    # Add tasks quickly, remove them slowly, so the count does not flap up and
    # down around the threshold.
    scale_out_cooldown = 60
    scale_in_cooldown  = 300
  }
}

# Safety net: also scale out if the tasks get busy for any other reason. With
# two policies, scaling out happens if either asks for it, and scaling in only
# when both agree.
resource "aws_appautoscaling_policy" "cpu" {
  name               = "${var.project}-cpu"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.app.service_namespace
  scalable_dimension = aws_appautoscaling_target.app.scalable_dimension
  resource_id        = aws_appautoscaling_target.app.resource_id

  target_tracking_scaling_policy_configuration {
    target_value = var.cpu_target_percent

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }

    scale_out_cooldown = 60
    scale_in_cooldown  = 300
  }
}
