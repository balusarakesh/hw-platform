output "dashboard_url" {
  value = "https://${var.region}.console.aws.amazon.com/cloudwatch/home?region=${var.region}#dashboards/dashboard/${aws_cloudwatch_dashboard.overview.dashboard_name}"
}

output "alb_arn_suffix" {
  value = local.alb
}
