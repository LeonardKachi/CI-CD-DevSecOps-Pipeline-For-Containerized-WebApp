# ALB module
#
# The load balancer: the only public entry point to the application. It accepts
# web traffic from the internet and forwards it to healthy app tasks in the
# private subnets. Users never connect to a task directly.
#
# Also builds the S3 bucket that receives the load balancer access logs, which
# record every request and are the main record for investigations.

data "aws_caller_identity" "current" {}

# --- Load balancer --------------------------------------------------------

resource "aws_lb" "this" {
  name               = "${var.project}-alb"
  load_balancer_type = "application"
  internal           = false
  security_groups    = [var.alb_security_group_id]
  subnets            = var.public_subnet_ids

  # Rejects requests with malformed headers instead of passing them on. This
  # blocks a family of HTTP request smuggling attacks.
  drop_invalid_header_fields = true

  # Nginx keeps idle connections open for 75 seconds, longer than this value.
  # That ordering is required. If the backend closed connections first, the
  # load balancer could reuse a dead one and return 502 errors.
  idle_timeout = var.idle_timeout

  enable_deletion_protection = var.enable_deletion_protection

  access_logs {
    bucket  = aws_s3_bucket.logs.id
    enabled = true
  }

  # The bucket must already allow delivery, or the load balancer is refused.
  depends_on = [aws_s3_bucket_policy.logs]
}

# --- Target group ---------------------------------------------------------
# The set of app tasks the load balancer sends traffic to. Fargate tasks have
# their own network interface, so they are registered by IP address.

resource "aws_lb_target_group" "app" {
  name_prefix = "app-"
  vpc_id      = var.vpc_id
  port        = var.target_port
  protocol    = "HTTP"
  target_type = "ip"

  # Shorter than the 300 second default. A static site has no long requests, so
  # old tasks can leave quickly and deployments finish sooner.
  deregistration_delay = 30

  # A task only receives traffic after it passes two checks in a row, and is
  # taken out after three failures. This is also what lets a bad deployment be
  # detected and rolled back instead of serving errors.
  health_check {
    path                = var.health_check_path
    protocol            = "HTTP"
    port                = "traffic-port"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = {
    Name = "${var.project}-app"
  }

  # A target group in use cannot be deleted. Create the new one first.
  lifecycle {
    create_before_destroy = true
  }
}

# Plain HTTP for now, as agreed. The planned upgrade is an HTTPS listener with an
# ACM certificate, and this listener becoming a redirect to it.
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = var.listener_port
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# --- Access log bucket ----------------------------------------------------
# Load balancers can only write access logs to a bucket encrypted with S3-managed
# keys (SSE-S3). KMS keys are not supported for this, so this is the one storage
# resource here that does not use the project key.

resource "aws_s3_bucket" "logs" {
  bucket        = "${var.project}-alb-logs-${data.aws_caller_identity.current.account_id}"
  force_destroy = var.force_destroy_log_bucket
}

resource "aws_s3_bucket_ownership_controls" "logs" {
  bucket = aws_s3_bucket.logs.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "logs" {
  bucket = aws_s3_bucket.logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id

  rule {
    id     = "expire-access-logs"
    status = "Enabled"

    filter {}

    expiration {
      days = var.access_log_retention_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# Regions opened before August 2022 deliver logs through a regional AWS account.
data "aws_elb_service_account" "this" {
  count = var.use_regional_elb_account ? 1 : 0
}

data "aws_iam_policy_document" "logs" {
  # The load balancer service may add log files, and only under this account's
  # own folder, so it cannot write anywhere else in the bucket.
  dynamic "statement" {
    for_each = var.use_regional_elb_account ? [1] : []

    content {
      sid       = "AllowLoadBalancerLogDeliveryRegionalAccount"
      effect    = "Allow"
      actions   = ["s3:PutObject"]
      resources = ["${aws_s3_bucket.logs.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]

      principals {
        type        = "AWS"
        identifiers = [data.aws_elb_service_account.this[0].arn]
      }
    }
  }

  # Same permission for regions that use a service principal instead.
  statement {
    sid       = "AllowLoadBalancerLogDeliveryServicePrincipal"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.logs.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]

    principals {
      type        = "Service"
      identifiers = ["logdelivery.elasticloadbalancing.amazonaws.com"]
    }
  }

  # Refuse any request that is not encrypted in transit.
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]

    resources = [
      aws_s3_bucket.logs.arn,
      "${aws_s3_bucket.logs.arn}/*",
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

resource "aws_s3_bucket_policy" "logs" {
  bucket = aws_s3_bucket.logs.id
  policy = data.aws_iam_policy_document.logs.json

  depends_on = [aws_s3_bucket_public_access_block.logs]
}
