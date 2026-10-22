# Node alarms. Nodes are replaced by Cluster Autoscaler, node auto repair and power.py, so alarms
# never target a specific instance: they use the [ClusterName] dimension set with Maximum/Minimum
# ("the worst node"), and the hw-overview dashboard shows the per-node breakdown.

resource "aws_cloudwatch_metric_alarm" "nodes_not_ready" {
  alarm_name        = "hw-nodes-not-ready"
  alarm_description = "A node has been NotReady for 5 minutes. Node auto repair should replace it. Check first: `kubectl get nodes`, EKS node health (eks-node-monitoring-agent conditions), EC2 status checks."

  namespace   = "ContainerInsights"
  metric_name = "cluster_failed_node_count"
  dimensions  = { ClusterName = local.cluster_name }
  statistic   = "Maximum"
  period      = 60

  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  evaluation_periods  = 5
  datapoints_to_alarm = 5
  treat_missing_data  = "notBreaching"

  alarm_actions = local.actions
  ok_actions    = local.actions
}

# Replaces the Karpenter "capacity limit" alarms (Karpenter is blocked by the account SCP):
# Cluster Autoscaler can't add nodes past the node group's max_size.
resource "aws_cloudwatch_metric_alarm" "nodes_at_max" {
  alarm_name        = "hw-nodes-at-max"
  alarm_description = "Cluster has been at the node group max (${var.node_group_max_size} nodes) for 10 minutes; Cluster Autoscaler can't add more. Check first: hw-pods-pending, cluster-autoscaler logs, then raise max_size in terraform/cluster/eks.tf."

  namespace   = "ContainerInsights"
  metric_name = "cluster_node_count"
  dimensions  = { ClusterName = local.cluster_name }
  statistic   = "Maximum"
  period      = 60

  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = var.node_group_max_size
  evaluation_periods  = 10
  datapoints_to_alarm = 10
  treat_missing_data  = "notBreaching"

  alarm_actions = local.actions
  ok_actions    = local.actions
}

# Every instance in this (single-purpose) account is an EKS node, so one Metrics Insights query
# over AWS/EC2 covers nodes that come and go without per-instance alarms.
resource "aws_cloudwatch_metric_alarm" "ec2_status_check" {
  alarm_name        = "hw-nodes-ec2-status-check"
  alarm_description = "An EC2 instance is failing system/instance/EBS status checks. Node auto repair should replace it. Check first: EC2 console status checks, AWS Health events for the instance."

  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "q1"
    expression  = "SELECT MAX(StatusCheckFailed) FROM SCHEMA(\"AWS/EC2\", InstanceId)"
    period      = 60
    label       = "Status check failed (any instance)"
    return_data = true
  }

  alarm_actions = local.actions
  ok_actions    = local.actions
}

resource "aws_cloudwatch_metric_alarm" "node_network_throughput" {
  alarm_name        = "hw-nodes-network-throughput"
  alarm_description = "A node has been above ${var.node_bandwidth_alarm_percent}% of its baseline bandwidth (${var.node_baseline_bandwidth_gbps} Gbps) for 5 minutes; it is spending burst credits and will be shaped. Check first: per-node network on hw-overview, ENA bw_*_allowance_exceeded."

  namespace   = "ContainerInsights"
  metric_name = "node_network_total_bytes" # bytes/second
  dimensions  = { ClusterName = local.cluster_name }
  statistic   = "Maximum"
  period      = 60

  comparison_operator = "GreaterThanThreshold"
  threshold           = var.node_baseline_bandwidth_gbps * 1000000000 / 8 * var.node_bandwidth_alarm_percent / 100
  evaluation_periods  = 5
  datapoints_to_alarm = 5
  treat_missing_data  = "notBreaching"

  alarm_actions = local.actions
  ok_actions    = local.actions
}

# Linux netfilter conntrack table (kube-proxy/iptables). When full, new connections are dropped.
resource "aws_cloudwatch_metric_alarm" "node_conntrack_table" {
  alarm_name        = "hw-nodes-conntrack-table"
  alarm_description = "A node's conntrack table is > ${var.conntrack_table_alarm_percent}% full for 5 minutes; new connections will be dropped when it fills. Check first: per-node conntrack on hw-overview, connection-heavy pods, nf_conntrack_max."

  comparison_operator = "GreaterThanThreshold"
  threshold           = var.conntrack_table_alarm_percent
  evaluation_periods  = 5
  datapoints_to_alarm = 5
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "pct"
    expression  = "100 * entries / limit"
    label       = "conntrack % used (worst node)"
    return_data = true
  }
  metric_query {
    id = "entries"
    metric {
      namespace   = "hw/Prometheus"
      metric_name = "node_nf_conntrack_entries"
      dimensions  = { ClusterName = local.cluster_name }
      stat        = "Maximum"
      period      = 60
    }
  }
  metric_query {
    id = "limit"
    metric {
      namespace   = "hw/Prometheus"
      metric_name = "node_nf_conntrack_entries_limit"
      dimensions  = { ClusterName = local.cluster_name }
      stat        = "Minimum"
      period      = 60
    }
  }

  alarm_actions = local.actions
  ok_actions    = local.actions
}

# ENA driver counters: packets queued or dropped because the instance exceeded an EC2 network
# allowance. Any increase is worth knowing about.
# TODO-verify: whether the CloudWatch agent publishes Prometheus counters as per-scrape deltas
# (assumed here: Sum > 0) or cumulative totals (then switch to RATE()/DIFF() metric math).
locals {
  ena_allowances = {
    bw-in      = { metric = "node_ethtool_bw_in_allowance_exceeded", what = "inbound bandwidth" }
    bw-out     = { metric = "node_ethtool_bw_out_allowance_exceeded", what = "outbound bandwidth" }
    pps        = { metric = "node_ethtool_pps_allowance_exceeded", what = "packets per second" }
    conntrack  = { metric = "node_ethtool_conntrack_allowance_exceeded", what = "tracked connections" }
    link-local = { metric = "node_ethtool_linklocal_allowance_exceeded", what = "link-local (DNS/IMDS/NTP) packets per second" }
  }
}

resource "aws_cloudwatch_metric_alarm" "ena_allowance_exceeded" {
  for_each = local.ena_allowances

  alarm_name        = "hw-nodes-ena-${each.key}-exceeded"
  alarm_description = "A node exceeded its EC2 ${each.value.what} allowance in the last 5 minutes (packets were queued or dropped). Check first: per-node ENA counters on hw-overview; fix is a bigger instance type or spreading traffic."

  namespace   = "hw/Prometheus"
  metric_name = each.value.metric
  dimensions  = { ClusterName = local.cluster_name }
  statistic   = "Sum"
  period      = 300

  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  evaluation_periods  = 1
  treat_missing_data  = "notBreaching"

  alarm_actions = local.actions
  ok_actions    = local.actions
}

resource "aws_cloudwatch_metric_alarm" "ena_conntrack_allowance_low" {
  alarm_name        = "hw-nodes-ena-conntrack-allowance-low"
  alarm_description = "A node has fewer than ${var.conntrack_allowance_min_available} tracked connections left before hitting the EC2 conntrack allowance. Check first: connection counts per pod, idle-timeout settings, instance size."

  namespace   = "hw/Prometheus"
  metric_name = "node_ethtool_conntrack_allowance_available"
  dimensions  = { ClusterName = local.cluster_name }
  statistic   = "Minimum"
  period      = 60

  comparison_operator = "LessThanThreshold"
  threshold           = var.conntrack_allowance_min_available
  evaluation_periods  = 5
  datapoints_to_alarm = 5
  treat_missing_data  = "notBreaching"

  alarm_actions = local.actions
  ok_actions    = local.actions
}
