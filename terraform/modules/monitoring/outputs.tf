output "sns_topic_arn" {
  description = "Alarm topic. Other modules can send notifications to it."
  value       = aws_sns_topic.alerts.arn
}

output "dashboard_name" {
  description = "Name of the CloudWatch dashboard."
  value       = aws_cloudwatch_dashboard.this.dashboard_name
}

output "dashboard_url" {
  description = "Link to the dashboard in the AWS console."
  value       = "https://console.aws.amazon.com/cloudwatch/home?region=${data.aws_region.current.region}#dashboards:name=${aws_cloudwatch_dashboard.this.dashboard_name}"
}

output "alarm_names" {
  description = "Names of all alarms in this module."
  value = [
    aws_cloudwatch_metric_alarm.no_healthy_targets.alarm_name,
    aws_cloudwatch_metric_alarm.unhealthy_targets.alarm_name,
    aws_cloudwatch_metric_alarm.server_errors.alarm_name,
    aws_cloudwatch_metric_alarm.cpu_high.alarm_name,
    aws_cloudwatch_metric_alarm.memory_high.alarm_name,
  ]
}
