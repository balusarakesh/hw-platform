# Pod, HPA and control-plane alarms.
#
# Container Insights (enhanced observability) metrics are published with a [ClusterName] dimension set,
# so one alarm covers every namespace. Names below follow the Container Insights enhanced observability
# docs; TODO-verify against `aws cloudwatch list-metrics --namespace ContainerInsights` once the cluster
# is up (they can differ between agent versions).

locals {
  ci_cluster = { ClusterName = local.cluster_name }

  pod_alarms = {
    unavailable = {
      metric      = "kube_deployment_status_replicas_unavailable"
      minutes     = 5
      description = "A Deployment has had unavailable replicas for 5 minutes. Check first: `kubectl get deploy -A`, `kubectl describe pod` events (image pull, probes, OOM)."
    }
    crashloop = {
      metric      = "pod_container_status_waiting_reason_crash_loop_back_off"
      minutes     = 5
      description = "A container has been in CrashLoopBackOff for 5 minutes. Check first: `kubectl logs --previous`, recent deploys (ArgoCD history)."
    }
    # Also the "pods unschedulable" signal for autoscaling: pending past 10 minutes means Cluster
    # Autoscaler couldn't add capacity (node group at max, or requests that fit no node).
    pending = {
      metric      = "pod_status_pending"
      minutes     = 10
      description = "Pods Pending for 10 minutes. Check first: `kubectl get events -A --field-selector reason=FailedScheduling`, hw-nodes-at-max alarm, cluster-autoscaler logs."
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "pods" {
  for_each = local.pod_alarms

  alarm_name        = "hw-pods-${each.key}"
  alarm_description = each.value.description

  namespace   = "ContainerInsights"
  metric_name = each.value.metric
  dimensions  = local.ci_cluster
  statistic   = "Maximum"
  period      = 60

  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  evaluation_periods  = each.value.minutes
  datapoints_to_alarm = each.value.minutes
  treat_missing_data  = "notBreaching"

  alarm_actions = local.actions
  ok_actions    = local.actions
}

# HPA pinned at maxReplicas: it wants more pods than it's allowed. Either load is unusually high
# (see hw-app-high-request-rate) or maxReplicas is too low. From kube-state-metrics via the
# cloudwatch-agent-prometheus scraper (namespace hw/Prometheus).
# Not alarmed: the ScalingLimited condition, because it is also true at minReplicas (idle), which
# would page all night.
resource "aws_cloudwatch_metric_alarm" "hpa_at_max" {
  alarm_name        = "hw-hpa-at-max"
  alarm_description = "HPA ${var.hpa_namespace}/${var.hpa_name} has been at maxReplicas for 5 minutes. Check first: request rate and per-route latency on hw-overview, pod CPU/memory; then raise hpa.maxReplicas in gitops/apps/hello-world/values.yaml (and node group max if pods go Pending)."

  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  evaluation_periods  = 5
  datapoints_to_alarm = 5
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "ratio"
    expression  = "current / max"
    label       = "current / max replicas"
    return_data = true
  }
  metric_query {
    id = "current"
    metric {
      namespace   = "hw/Prometheus"
      metric_name = "kube_horizontalpodautoscaler_status_current_replicas"
      dimensions = {
        ClusterName             = local.cluster_name
        namespace               = var.hpa_namespace
        horizontalpodautoscaler = var.hpa_name
      }
      stat   = "Maximum"
      period = 60
    }
  }
  metric_query {
    id = "max"
    metric {
      namespace   = "hw/Prometheus"
      metric_name = "kube_horizontalpodautoscaler_spec_max_replicas"
      dimensions = {
        ClusterName             = local.cluster_name
        namespace               = var.hpa_namespace
        horizontalpodautoscaler = var.hpa_name
      }
      stat   = "Maximum"
      period = 60
    }
  }

  alarm_actions = local.actions
  ok_actions    = local.actions
}

# EKS publishes control-plane metrics to AWS/EKS for free (no scraping). Only P99 is vended, so
# "p90 > 3s" is implemented as P99 > 3s (P99 >= p90, so this fires whenever p90 would) - see GAPS.
# TODO-verify metric names with `aws cloudwatch list-metrics --namespace AWS/EKS` once the cluster exists.
locals {
  apiserver_verbs = ["GET", "LIST", "POST", "PUT", "PATCH", "DELETE"]
}

resource "aws_cloudwatch_metric_alarm" "apiserver_latency" {
  alarm_name        = "hw-controlplane-api-latency"
  alarm_description = "EKS API server P99 request latency > ${var.apiserver_latency_seconds}s (worst verb) for 5 minutes. Check first: AWS Health dashboard for EKS, apiserver_request_total_429 (throttling), noisy controllers / LIST-heavy clients in the audit log."

  comparison_operator = "GreaterThanThreshold"
  threshold           = var.apiserver_latency_seconds
  evaluation_periods  = 5
  datapoints_to_alarm = 5
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "worst"
    expression  = "MAX([${join(",", [for v in local.apiserver_verbs : lower(v)])}])"
    label       = "API P99 latency (worst verb)"
    return_data = true
  }

  dynamic "metric_query" {
    for_each = local.apiserver_verbs
    content {
      id = lower(metric_query.value)
      metric {
        namespace   = "AWS/EKS"
        metric_name = "apiserver_request_duration_seconds_${metric_query.value}_P99"
        dimensions  = { ClusterName = local.cluster_name }
        stat        = "Maximum"
        period      = 60
      }
    }
  }

  alarm_actions = local.actions
  ok_actions    = local.actions
}

resource "aws_cloudwatch_metric_alarm" "apiserver_errors" {
  for_each = {
    "5xx" = { metric = "apiserver_request_total_5XX", what = "server errors" }
    "429" = { metric = "apiserver_request_total_429", what = "throttled requests" }
  }

  alarm_name        = "hw-controlplane-api-${each.key}"
  alarm_description = "EKS API server returning ${each.value.what} for 5 minutes straight. Check first: AWS Health dashboard, audit log for the client generating the load, admission webhooks timing out."

  namespace   = "AWS/EKS"
  metric_name = each.value.metric
  dimensions  = { ClusterName = local.cluster_name }
  statistic   = "Sum"
  period      = 60

  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  evaluation_periods  = 5
  datapoints_to_alarm = 5
  treat_missing_data  = "notBreaching"

  alarm_actions = local.actions
  ok_actions    = local.actions
}
