# hw-overview: the first screen for the interview walkthrough and for any alarm.
# Rows: alarm status -> app (ALB + per-route) -> pods/HPA -> nodes -> node network -> control plane / DB.
# Per-node graphs use SEARCH() so they follow whatever nodes currently exist.

locals {
  cn = local.cluster_name

  per_node = { for m in [
    "node_nf_conntrack_entries",
    ] : m => "SEARCH('{hw/Prometheus,ClusterName,NodeName} ClusterName=\"${local.cn}\" MetricName=\"${m}\"', 'Maximum', 60)"
  }

  widgets = [
    {
      type = "alarm", x = 0, y = 0, width = 24, height = 4
      properties = {
        title = "Alarms"
        alarms = concat(
          [for a in aws_cloudwatch_metric_alarm.pods : a.arn],
          [for a in aws_cloudwatch_metric_alarm.ena_allowance_exceeded : a.arn],
          [for a in aws_cloudwatch_metric_alarm.apiserver_errors : a.arn],
          [
            aws_cloudwatch_metric_alarm.alb_high_request_rate.arn,
            aws_cloudwatch_metric_alarm.waf_rate_limited.arn,
            aws_cloudwatch_metric_alarm.alb_high_latency.arn,
            aws_cloudwatch_metric_alarm.alb_5xx_rate.arn,
            aws_cloudwatch_metric_alarm.alb_unhealthy_targets.arn,
            aws_cloudwatch_metric_alarm.aurora_acu_high.arn,
            aws_cloudwatch_metric_alarm.hpa_at_max.arn,
            aws_cloudwatch_metric_alarm.nodes_not_ready.arn,
            aws_cloudwatch_metric_alarm.nodes_at_max.arn,
            aws_cloudwatch_metric_alarm.ec2_status_check.arn,
            aws_cloudwatch_metric_alarm.node_network_throughput.arn,
            aws_cloudwatch_metric_alarm.node_conntrack_table.arn,
            aws_cloudwatch_metric_alarm.ena_conntrack_allowance_low.arn,
            aws_cloudwatch_metric_alarm.apiserver_latency.arn,
          ],
        )
      }
    },
    {
      type = "metric", x = 0, y = 4, width = 8, height = 6
      properties = {
        title       = "Requests/min (ALB)", region = var.region, stat = "Sum", period = 60
        metrics     = [["AWS/ApplicationELB", "RequestCount", "LoadBalancer", local.alb]]
        annotations = { horizontal = [{ label = "${var.high_rps_threshold} rps", value = var.high_rps_threshold * 60 }] }
      }
    },
    {
      type = "metric", x = 8, y = 4, width = 8, height = 6
      properties = {
        title = "Target response time (ALB)", region = var.region, period = 60
        metrics = [
          ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", local.alb, { stat = "p50", label = "p50" }],
          ["...", { stat = "p95", label = "p95" }],
          ["...", { stat = "p99", label = "p99" }],
        ]
      }
    },
    {
      type = "metric", x = 16, y = 4, width = 8, height = 6
      properties = {
        title = "HTTP status (ALB)", region = var.region, stat = "Sum", period = 60
        metrics = [
          ["AWS/ApplicationELB", "HTTPCode_Target_2XX_Count", "LoadBalancer", local.alb],
          [".", "HTTPCode_Target_4XX_Count", ".", "."],
          [".", "HTTPCode_Target_5XX_Count", ".", "."],
          [".", "HTTPCode_ELB_5XX_Count", ".", "."],
        ]
      }
    },
    {
      type = "metric", x = 0, y = 10, width = 12, height = 6
      properties = {
        title   = "App requests by route and status (Prometheus)", region = var.region, stat = "Sum", period = 60
        metrics = [[{ expression = "SEARCH('{hw/Prometheus,ClusterName,code,route} ClusterName=\"${local.cn}\" MetricName=\"http_requests_total\"', 'Sum', 60)", id = "routes" }]]
      }
    },
    {
      type = "metric", x = 12, y = 10, width = 12, height = 6
      properties = {
        title = "HPA replicas (current vs max)", region = var.region, stat = "Maximum", period = 60
        metrics = [
          ["hw/Prometheus", "kube_horizontalpodautoscaler_status_current_replicas", "ClusterName", local.cn, "namespace", var.hpa_namespace, "horizontalpodautoscaler", var.hpa_name],
          [".", "kube_horizontalpodautoscaler_spec_max_replicas", ".", ".", ".", ".", ".", "."],
          [".", "kube_horizontalpodautoscaler_spec_min_replicas", ".", ".", ".", ".", ".", "."],
        ]
      }
    },
    {
      type = "metric", x = 0, y = 16, width = 8, height = 6
      properties = {
        title = "Nodes", region = var.region, stat = "Maximum", period = 60
        metrics = [
          ["ContainerInsights", "cluster_node_count", "ClusterName", local.cn],
          [".", "cluster_failed_node_count", ".", "."],
        ]
        annotations = { horizontal = [{ label = "node group max", value = local.node_group_max_size }] }
      }
    },
    {
      type = "metric", x = 8, y = 16, width = 8, height = 6
      properties = {
        title = "Node CPU / memory % (worst node)", region = var.region, stat = "Maximum", period = 60
        metrics = [
          ["ContainerInsights", "node_cpu_utilization", "ClusterName", local.cn],
          [".", "node_memory_utilization", ".", "."],
        ]
      }
    },
    {
      type = "metric", x = 16, y = 16, width = 8, height = 6
      properties = {
        title   = "Pods: pending / unavailable / crashloop", region = var.region, stat = "Maximum", period = 60
        metrics = [for k, v in local.pod_alarms : ["ContainerInsights", v.metric, "ClusterName", local.cn, { label = k }]]
      }
    },
    {
      type = "metric", x = 0, y = 22, width = 8, height = 6
      properties = {
        title       = "Node network bytes/s (worst node)", region = var.region, stat = "Maximum", period = 60
        metrics     = [["ContainerInsights", "node_network_total_bytes", "ClusterName", local.cn]]
        annotations = { horizontal = [{ label = "baseline", value = local.node_baseline_bandwidth_gbps * 1000000000 / 8 }] }
      }
    },
    {
      type = "metric", x = 8, y = 22, width = 8, height = 6
      properties = {
        title   = "Conntrack entries per node", region = var.region, period = 60
        metrics = [[{ expression = local.per_node["node_nf_conntrack_entries"], id = "ct" }]]
      }
    },
    {
      type = "metric", x = 16, y = 22, width = 8, height = 6
      properties = {
        title = "ENA allowance exceeded per instance (packets/min)", region = var.region, period = 60
        metrics = [for i, m in [
          "ethtool_bw_in_allowance_exceeded",
          "ethtool_bw_out_allowance_exceeded",
          "ethtool_pps_allowance_exceeded",
          "ethtool_conntrack_allowance_exceeded",
          "ethtool_linklocal_allowance_exceeded",
        ] : [{ expression = "DIFF(SEARCH('{hw/ENA,InstanceId,driver,interface} MetricName=\"${m}\"', 'Maximum', 60))", id = "ena${i}" }]]
      }
    },
    {
      type = "metric", x = 0, y = 28, width = 12, height = 6
      properties = {
        title       = "EKS API server P99 latency by verb (s)", region = var.region, stat = "Maximum", period = 60
        metrics     = [for v in local.apiserver_verbs : ["AWS/EKS", "apiserver_request_duration_seconds_${v}_P99", "ClusterName", local.cn, { label = v }]]
        annotations = { horizontal = [{ label = "threshold", value = var.apiserver_latency_seconds }] }
      }
    },
    {
      type = "metric", x = 12, y = 28, width = 12, height = 6
      properties = {
        title = "Aurora capacity", region = var.region, period = 60
        metrics = [
          ["AWS/RDS", "ServerlessDatabaseCapacity", "DBClusterIdentifier", local.p.aurora_cluster_id, { stat = "Average", label = "ACUs" }],
          [".", "ACUUtilization", ".", ".", { stat = "Average", label = "ACU %", yAxis = "right" }],
        ]
      }
    },
    {
      type = "metric", x = 0, y = 34, width = 24, height = 6
      properties = {
        title = "WAF: allowed vs blocked (429 = rate-limit-per-ip)", region = var.region, stat = "Sum", period = 60
        metrics = [
          ["AWS/WAFV2", "AllowedRequests", "WebACL", "${local.cn}-app", "Region", var.region, "Rule", "ALL", { label = "allowed" }],
          [".", "BlockedRequests", ".", ".", ".", ".", "Rule", "rate-limit-per-ip", { label = "rate limited (429)" }],
          [".", "BlockedRequests", ".", ".", ".", ".", "Rule", "aws-common", { label = "managed: common" }],
          [".", "BlockedRequests", ".", ".", ".", ".", "Rule", "aws-known-bad-inputs", { label = "managed: bad inputs" }],
        ]
      }
    },
  ]
}

resource "aws_cloudwatch_dashboard" "overview" {
  dashboard_name = "hw-overview"
  dashboard_body = jsonencode({ widgets = local.widgets })
}
