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

# Multi-time-series alarm: the Metrics Insights query is re-run at every evaluation and GROUP BY
# InstanceId evaluates each instance on its own, so nodes that come and go are covered without
# per-instance alarms. Every instance in this (single-purpose) account is an EKS node.
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
    expression  = "SELECT MAX(StatusCheckFailed) FROM SCHEMA(\"AWS/EC2\", InstanceId) GROUP BY InstanceId ORDER BY MAX() DESC"
    period      = 60
    label       = "Status check failed (per instance)"
    return_data = true
  }

  alarm_actions = local.actions
  ok_actions    = local.actions
}

resource "aws_cloudwatch_metric_alarm" "node_network_throughput" {
  alarm_name        = "hw-nodes-network-throughput"
  alarm_description = "A node has been above ${var.node_bandwidth_alarm_percent}% of its baseline bandwidth (${local.node_baseline_bandwidth_gbps} Gbps on ${local.node_instance_type}) for 5 minutes; it will be shaped. The alarm lists which node(s). Check first: per-node network on hw-overview, ENA bw_*_allowance_exceeded."

  comparison_operator = "GreaterThanThreshold"
  threshold           = local.node_baseline_bandwidth_gbps * 1000000000 / 8 * var.node_bandwidth_alarm_percent / 100
  evaluation_periods  = 5
  datapoints_to_alarm = 5
  treat_missing_data  = "notBreaching"

  # Multi-time-series: one evaluation per node (bytes/second).
  metric_query {
    id          = "q1"
    expression  = "SELECT MAX(node_network_total_bytes) FROM SCHEMA(ContainerInsights, ClusterName, InstanceId, NodeName) WHERE ClusterName = '${local.cluster_name}' GROUP BY NodeName ORDER BY MAX() DESC"
    period      = 60
    label       = "Network bytes/s (per node)"
    return_data = true
  }

  alarm_actions = local.actions
  ok_actions    = local.actions
}

# Linux netfilter conntrack table (kube-proxy/iptables). When full, new connections are dropped.
resource "aws_cloudwatch_metric_alarm" "node_conntrack_table" {
  alarm_name        = "hw-nodes-conntrack-table"
  alarm_description = "A node's conntrack table is > ${var.conntrack_table_alarm_percent}% full (limit ${local.node_conntrack_limit} on ${local.node_instance_type}) for 5 minutes; new connections are dropped when it fills. The alarm lists which node(s). Check first: per-node conntrack on hw-overview, connection-heavy pods."

  comparison_operator = "GreaterThanThreshold"
  # Metrics Insights can't divide two metrics, so the % is applied to the derived limit instead.
  threshold           = floor(local.node_conntrack_limit * var.conntrack_table_alarm_percent / 100)
  evaluation_periods  = 5
  datapoints_to_alarm = 5
  treat_missing_data  = "notBreaching"

  # Multi-time-series: one evaluation per node.
  metric_query {
    id          = "q1"
    expression  = "SELECT MAX(node_nf_conntrack_entries) FROM SCHEMA(\"hw/Prometheus\", ClusterName, NodeName) WHERE ClusterName = '${local.cluster_name}' GROUP BY NodeName ORDER BY MAX() DESC"
    period      = 60
    label       = "conntrack entries (per node)"
    return_data = true
  }

  alarm_actions = local.actions
  ok_actions    = local.actions
}

# ENA driver counters: packets queued or dropped because an instance exceeded an EC2 network
# allowance. Published by the CloudWatch agent's ethtool plugin (namespace hw/ENA) as cumulative
# counters, aggregated across nodes (no dimensions). The alarm fires on the per-minute increase
# (DIFF of the cluster-wide Sum). These stay cluster-wide on purpose: they are cumulative counters, and
# a per-instance rate needs DIFF/RATE, which multi-time-series (Metrics Insights) alarms can't apply. Not "any increase": burstable t4g nodes exceed their allowances
# briefly during image pulls, which isn't worth a page.
locals {
  ena_allowances = {
    bw-in      = { metric = "ethtool_bw_in_allowance_exceeded", what = "inbound bandwidth" }
    bw-out     = { metric = "ethtool_bw_out_allowance_exceeded", what = "outbound bandwidth" }
    pps        = { metric = "ethtool_pps_allowance_exceeded", what = "packets per second" }
    conntrack  = { metric = "ethtool_conntrack_allowance_exceeded", what = "tracked connections" }
    link-local = { metric = "ethtool_linklocal_allowance_exceeded", what = "link-local (DNS/IMDS/NTP) packets per second" }
  }
}

resource "aws_cloudwatch_metric_alarm" "ena_allowance_exceeded" {
  for_each = local.ena_allowances

  alarm_name        = "hw-nodes-ena-${each.key}-exceeded"
  alarm_description = "Nodes have been exceeding their EC2 ${each.value.what} allowance (more than ${var.ena_exceeded_per_minute} packets/min queued or dropped, 3 of the last 5 minutes). Check first: ENA panel on hw-overview (which instance), then traffic per pod; fix is a bigger instance type or spreading traffic."

  comparison_operator = "GreaterThanThreshold"
  threshold           = var.ena_exceeded_per_minute
  evaluation_periods  = 5
  datapoints_to_alarm = 3
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "increase"
    expression  = "DIFF(total)"
    label       = "${each.value.metric} per minute (cluster)"
    return_data = true
  }

  metric_query {
    id = "total"
    metric {
      namespace   = "hw/ENA"
      metric_name = each.value.metric
      stat        = "Sum"
      period      = 60
    }
  }

  alarm_actions = local.actions
  ok_actions    = local.actions
}

resource "aws_cloudwatch_metric_alarm" "ena_conntrack_allowance_low" {
  alarm_name        = "hw-nodes-ena-conntrack-allowance-low"
  alarm_description = "A node has fewer than ${var.conntrack_allowance_min_available} tracked connections left before hitting the EC2 conntrack allowance. The alarm lists which instance(s). Check first: connection counts per pod, idle-timeout settings, instance size."

  comparison_operator = "LessThanThreshold"
  threshold           = var.conntrack_allowance_min_available
  evaluation_periods  = 5
  datapoints_to_alarm = 5
  treat_missing_data  = "notBreaching"

  # Multi-time-series: one evaluation per instance (gauge, so no DIFF needed).
  metric_query {
    id          = "q1"
    expression  = "SELECT MIN(ethtool_conntrack_allowance_available) FROM SCHEMA(\"hw/ENA\", InstanceId, driver, interface) GROUP BY InstanceId ORDER BY MIN() ASC"
    period      = 60
    label       = "ENA conntrack allowance available (per instance)"
    return_data = true
  }

  alarm_actions = local.actions
  ok_actions    = local.actions
}
