# Monitoring module
#
# Answers two questions: "is it working right now?" (the dashboard) and "tell me
# when it stops working" (the alarms and the email topic).
#
# Alarms are chosen to cover the ways this system can fail:
#   no healthy tasks      the site is down
#   unhealthy tasks       part of the capacity is failing
#   server errors         the site is up but returning errors
#   CPU and memory high   the tasks are overloaded, or auto scaling is not coping
#
# Every alarm sends a message when it fires and another when it recovers.

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  region     = data.aws_region.current.region
  account_id = data.aws_caller_identity.current.account_id

  alb_dimensions = {
    LoadBalancer = var.alb_arn_suffix
    TargetGroup  = var.target_group_arn_suffix
  }

  ecs_dimensions = {
    ClusterName = var.cluster_name
    ServiceName = var.service_name
  }
}

# --- Alert topic ------------------------------------------------------------

resource "aws_sns_topic" "alerts" {
  name              = "${var.project}-alerts"
  kms_master_key_id = var.kms_key_arn
}

# Who may use the topic. Only this project's alarms can publish to it, and
# nothing can use it without encryption in transit.
data "aws_iam_policy_document" "alerts" {
  statement {
    sid    = "AccountOwnerManagesTheTopic"
    effect = "Allow"
    actions = [
      "sns:GetTopicAttributes",
      "sns:SetTopicAttributes",
      "sns:AddPermission",
      "sns:RemovePermission",
      "sns:DeleteTopic",
      "sns:Subscribe",
      "sns:ListSubscriptionsByTopic",
      "sns:Publish",
    ]
    resources = [aws_sns_topic.alerts.arn]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${local.account_id}:root"]
    }
  }

  statement {
    sid       = "OnlyThisProjectsAlarmsCanPublish"
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]

    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:cloudwatch:${local.region}:${local.account_id}:alarm:${var.project}-*"]
    }
  }

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]

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

resource "aws_sns_topic_policy" "alerts" {
  arn    = aws_sns_topic.alerts.arn
  policy = data.aws_iam_policy_document.alerts.json
}

# The subscription stays "pending" until the owner of the address clicks the
# confirmation link AWS emails. Until then no alarm email is delivered.
resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# --- Alarms -----------------------------------------------------------------

# The site is down: the load balancer has no healthy task to send users to.
# Missing data counts as a failure here, because no tasks means no data.
resource "aws_cloudwatch_metric_alarm" "no_healthy_targets" {
  alarm_name          = "${var.project}-no-healthy-targets"
  alarm_description   = "No healthy tasks behind the load balancer. The site is down."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HealthyHostCount"
  dimensions          = local.alb_dimensions
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

# Part of the capacity is failing its health check, even though the site may
# still be serving. Catches a bad deployment or a failing zone early.
resource "aws_cloudwatch_metric_alarm" "unhealthy_targets" {
  alarm_name          = "${var.project}-unhealthy-targets"
  alarm_description   = "One or more tasks are failing the load balancer health check."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  dimensions          = local.alb_dimensions
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

# Server errors from either the load balancer itself or the tasks behind it,
# added together. FILL turns "no data" into zero, so a quiet minute is not
# mistaken for a problem. Needs 3 bad minutes out of 5, so one blip is ignored.
resource "aws_cloudwatch_metric_alarm" "server_errors" {
  alarm_name          = "${var.project}-server-errors"
  alarm_description   = "The site is returning HTTP 5xx errors."
  evaluation_periods  = 5
  datapoints_to_alarm = 3
  threshold           = var.error_5xx_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  metric_query {
    id = "elb5xx"

    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HTTPCode_ELB_5XX_Count"
      dimensions  = { LoadBalancer = var.alb_arn_suffix }
      stat        = "Sum"
      period      = 60
    }
  }

  metric_query {
    id = "target5xx"

    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HTTPCode_Target_5XX_Count"
      dimensions  = local.alb_dimensions
      stat        = "Sum"
      period      = 60
    }
  }

  metric_query {
    id          = "total"
    expression  = "FILL(elb5xx, 0) + FILL(target5xx, 0)"
    label       = "Server errors per minute"
    return_data = true
  }
}

# Tasks are overloaded. Auto scaling aims for 60% CPU, so staying above 80% means
# scaling is not keeping up, or the maximum task count has been reached.
resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name          = "${var.project}-cpu-high"
  alarm_description   = "Average CPU is high. Auto scaling is not keeping up, or is at its maximum."
  namespace           = "AWS/ECS"
  metric_name         = "CPUUtilization"
  dimensions          = local.ecs_dimensions
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 5
  datapoints_to_alarm = 3
  threshold           = var.cpu_alarm_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "memory_high" {
  alarm_name          = "${var.project}-memory-high"
  alarm_description   = "Average memory is high. Tasks may be restarted when they run out."
  namespace           = "AWS/ECS"
  metric_name         = "MemoryUtilization"
  dimensions          = local.ecs_dimensions
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 5
  datapoints_to_alarm = 3
  threshold           = var.memory_alarm_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

# --- Dashboard --------------------------------------------------------------
# One page that shows the health of the whole system. It reads left to right and
# top to bottom: traffic, errors and speed, then capacity, then the raw logs.

locals {
  dashboard_widgets = [
    {
      type   = "text"
      x      = 0
      y      = 0
      width  = 24
      height = 2
      properties = {
        markdown = "# ${var.project}: health at a glance\nTraffic, errors and speed on top. Capacity and alarms in the middle. Recent errors from the container logs at the bottom. Any alarm in red also sends an email."
      }
    },
    {
      type   = "metric"
      x      = 0
      y      = 2
      width  = 8
      height = 6
      properties = {
        title   = "Requests per minute"
        region  = local.region
        view    = "timeSeries"
        stacked = false
        period  = 60
        metrics = [
          ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", var.alb_arn_suffix, { stat = "Sum", label = "Requests" }],
        ]
      }
    },
    {
      type   = "metric"
      x      = 8
      y      = 2
      width  = 8
      height = 6
      properties = {
        title   = "Responses by type"
        region  = local.region
        view    = "timeSeries"
        stacked = true
        period  = 60
        metrics = [
          ["AWS/ApplicationELB", "HTTPCode_Target_2XX_Count", "LoadBalancer", var.alb_arn_suffix, "TargetGroup", var.target_group_arn_suffix, { stat = "Sum", label = "2xx success" }],
          ["AWS/ApplicationELB", "HTTPCode_Target_4XX_Count", "LoadBalancer", var.alb_arn_suffix, "TargetGroup", var.target_group_arn_suffix, { stat = "Sum", label = "4xx client errors" }],
          ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", var.alb_arn_suffix, "TargetGroup", var.target_group_arn_suffix, { stat = "Sum", label = "5xx from tasks" }],
          ["AWS/ApplicationELB", "HTTPCode_ELB_5XX_Count", "LoadBalancer", var.alb_arn_suffix, { stat = "Sum", label = "5xx from load balancer" }],
        ]
      }
    },
    {
      type   = "metric"
      x      = 16
      y      = 2
      width  = 8
      height = 6
      properties = {
        title   = "Response time (seconds)"
        region  = local.region
        view    = "timeSeries"
        stacked = false
        period  = 60
        metrics = [
          ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", var.alb_arn_suffix, "TargetGroup", var.target_group_arn_suffix, { stat = "Average", label = "Average" }],
          ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", var.alb_arn_suffix, "TargetGroup", var.target_group_arn_suffix, { stat = "p95", label = "Slowest 5%" }],
        ]
      }
    },
    {
      type   = "metric"
      x      = 0
      y      = 8
      width  = 8
      height = 6
      properties = {
        title   = "Healthy and unhealthy tasks"
        region  = local.region
        view    = "timeSeries"
        stacked = false
        period  = 60
        metrics = [
          ["AWS/ApplicationELB", "HealthyHostCount", "LoadBalancer", var.alb_arn_suffix, "TargetGroup", var.target_group_arn_suffix, { stat = "Minimum", label = "Healthy" }],
          ["AWS/ApplicationELB", "UnHealthyHostCount", "LoadBalancer", var.alb_arn_suffix, "TargetGroup", var.target_group_arn_suffix, { stat = "Maximum", label = "Unhealthy" }],
        ]
      }
    },
    {
      type   = "metric"
      x      = 8
      y      = 8
      width  = 8
      height = 6
      properties = {
        title   = "CPU and memory (percent)"
        region  = local.region
        view    = "timeSeries"
        stacked = false
        period  = 60
        metrics = [
          ["AWS/ECS", "CPUUtilization", "ClusterName", var.cluster_name, "ServiceName", var.service_name, { stat = "Average", label = "CPU" }],
          ["AWS/ECS", "MemoryUtilization", "ClusterName", var.cluster_name, "ServiceName", var.service_name, { stat = "Average", label = "Memory" }],
        ]
      }
    },
    {
      type   = "alarm"
      x      = 16
      y      = 8
      width  = 8
      height = 6
      properties = {
        title = "Alarm status"
        alarms = [
          aws_cloudwatch_metric_alarm.no_healthy_targets.arn,
          aws_cloudwatch_metric_alarm.unhealthy_targets.arn,
          aws_cloudwatch_metric_alarm.server_errors.arn,
          aws_cloudwatch_metric_alarm.cpu_high.arn,
          aws_cloudwatch_metric_alarm.memory_high.arn,
        ]
      }
    },
    {
      type   = "log"
      x      = 0
      y      = 14
      width  = 12
      height = 7
      properties = {
        title  = "Recent error responses (status 400 and above)"
        region = local.region
        view   = "table"
        query  = "SOURCE '${var.log_group_name}' | fields @timestamp, status, method, uri, client | filter status >= 400 | sort @timestamp desc | limit 20"
      }
    },
    {
      type   = "log"
      x      = 12
      y      = 14
      width  = 12
      height = 7
      properties = {
        title  = "Requests per 5 minutes by status"
        region = local.region
        view   = "bar"
        query  = "SOURCE '${var.log_group_name}' | filter ispresent(status) | stats count(*) as requests by bin(5m), status"
      }
    },
  ]
}

resource "aws_cloudwatch_dashboard" "this" {
  dashboard_name = "${var.project}-overview"
  dashboard_body = jsonencode({ widgets = local.dashboard_widgets })
}
