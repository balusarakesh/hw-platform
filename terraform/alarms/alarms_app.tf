# App-facing alarms on native ALB metrics: no scrape pipeline involved, so these keep working even if
# the in-cluster metrics path is broken. treat_missing_data = notBreaching everywhere so a powered-off
# cluster (no traffic, no nodes) stays quiet; power.py also disables actions on `down`.

resource "aws_cloudwatch_metric_alarm" "alb_high_request_rate" {
  alarm_name        = "hw-app-high-request-rate"
  alarm_description = "More than ${var.high_rps_threshold} req/s for 60s on the hw ALB. Check first: hw-overview dashboard (RPS by route), ALB access pattern / source IPs, HPA replicas."

  namespace   = "AWS/ApplicationELB"
  metric_name = "RequestCount"
  dimensions  = { LoadBalancer = local.alb }
  statistic   = "Sum"
  period      = 60

  comparison_operator = "GreaterThanThreshold"
  threshold           = var.high_rps_threshold * 60
  evaluation_periods  = 1
  treat_missing_data  = "notBreaching"

  alarm_actions = local.actions
  ok_actions    = local.actions
}

resource "aws_cloudwatch_metric_alarm" "alb_high_latency" {
  alarm_name        = "hw-app-high-latency"
  alarm_description = "ALB target response time p95 > ${var.latency_p95_seconds}s for 3 minutes. Check first: Aurora state (paused/resuming? ACU at max?), app logs in /aws/containerinsights/hw/application, pod CPU throttling."

  namespace          = "AWS/ApplicationELB"
  metric_name        = "TargetResponseTime"
  dimensions         = { LoadBalancer = local.alb }
  extended_statistic = "p95"
  period             = 60

  comparison_operator = "GreaterThanThreshold"
  threshold           = var.latency_p95_seconds
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  treat_missing_data  = "notBreaching"

  alarm_actions = local.actions
  ok_actions    = local.actions
}

resource "aws_cloudwatch_metric_alarm" "alb_5xx_rate" {
  alarm_name        = "hw-app-5xx-rate"
  alarm_description = "Target 5xx > ${var.error_rate_percent}% of requests for 5 minutes. Check first: app logs (DB errors?), db-bootstrap Job status, Aurora availability."

  comparison_operator = "GreaterThanThreshold"
  threshold           = var.error_rate_percent
  evaluation_periods  = 5
  datapoints_to_alarm = 5
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "rate"
    expression  = "IF(requests > 0, 100 * FILL(errors, 0) / requests, 0)"
    label       = "5xx %"
    return_data = true
  }
  metric_query {
    id = "errors"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HTTPCode_Target_5XX_Count"
      dimensions  = { LoadBalancer = local.alb }
      stat        = "Sum"
      period      = 60
    }
  }
  metric_query {
    id = "requests"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "RequestCount"
      dimensions  = { LoadBalancer = local.alb }
      stat        = "Sum"
      period      = 60
    }
  }

  alarm_actions = local.actions
  ok_actions    = local.actions
}

# UnHealthyHostCount only exists per (LoadBalancer, TargetGroup). Target groups are created by the
# controller with generated names, so a Metrics Insights query covers every TG behind this ALB.
resource "aws_cloudwatch_metric_alarm" "alb_unhealthy_targets" {
  alarm_name        = "hw-app-unhealthy-targets"
  alarm_description = "At least one ALB target unhealthy for 5 minutes. Check first: `kubectl -n hello-world get pods`, /healthz from inside the cluster, node NotReady alarm."

  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  evaluation_periods  = 5
  datapoints_to_alarm = 5
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "q1"
    expression  = "SELECT MAX(UnHealthyHostCount) FROM SCHEMA(\"AWS/ApplicationELB\", LoadBalancer, TargetGroup) WHERE LoadBalancer = '${local.alb}'"
    period      = 60
    label       = "Unhealthy targets"
    return_data = true
  }

  alarm_actions = local.actions
  ok_actions    = local.actions
}

resource "aws_cloudwatch_metric_alarm" "aurora_acu_high" {
  alarm_name        = "hw-db-acu-high"
  alarm_description = "Aurora at > ${var.aurora_acu_utilization_percent}% of max ACUs for 10 minutes. Check first: Performance Insights top SQL, connection count, then raise max_acu in terraform/persistent."

  namespace   = "AWS/RDS"
  metric_name = "ACUUtilization"
  dimensions  = { DBClusterIdentifier = local.p.aurora_cluster_id }
  statistic   = "Average"
  period      = 60

  comparison_operator = "GreaterThanThreshold"
  threshold           = var.aurora_acu_utilization_percent
  evaluation_periods  = 10
  datapoints_to_alarm = 10
  treat_missing_data  = "notBreaching"

  alarm_actions = local.actions
  ok_actions    = local.actions
}
