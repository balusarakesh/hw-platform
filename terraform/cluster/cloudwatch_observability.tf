# Configuration for the amazon-cloudwatch-observability EKS addon (wired up in eks.tf).
#
# Two agent workloads:
#   cloudwatch-agent             DaemonSet  Container Insights with enhanced observability (node/pod/
#                                           container/deployment metrics) - the addon's default job.
#   cloudwatch-agent-prometheus  Deployment Scrapes the Prometheus endpoints we opt in with the pod label
#                                           hw.io/scrape=true and publishes ONLY the allowlisted metrics
#                                           (CloudWatch bills per metric x dimension combination).
# A single scraper replica avoids every DaemonSet pod scraping every target (N x duplicates).
#
# The addon's bundled node-exporter and kube-state-metrics are disabled: their default requests
# (~250m CPU each, per node for node-exporter) don't fit 2 x t4g.medium, and they can't enable the
# ethtool collector. Slim, pinned versions run from gitops/apps/{node-exporter,kube-state-metrics}.

locals {
  # Every scraped series gets ClusterName (and NodeName where it applies) so alarms can use the
  # cluster-wide [ClusterName] dimension set and dashboards can drill into [ClusterName, NodeName].
  scrape_common_relabels = [
    { source_labels = ["__meta_kubernetes_pod_label_hw_io_scrape"], action = "keep", regex = "true" },
    {
      source_labels = ["__meta_kubernetes_pod_ip", "__meta_kubernetes_pod_container_port_number"]
      regex         = "(.+);(.+)"
      replacement   = "$1:$2"
      target_label  = "__address__"
    },
    { target_label = "ClusterName", replacement = var.project },
    { source_labels = ["__meta_kubernetes_pod_node_name"], target_label = "NodeName" },
  ]

  scrape_job = {
    for job, cfg in {
      hello-world        = { namespace = "hello-world", port = "metrics" }
      node-exporter      = { namespace = "node-exporter", port = "metrics" }
      kube-state-metrics = { namespace = "monitoring", port = "http" }
    } :
    job => {
      job_name              = job
      kubernetes_sd_configs = [{ role = "pod", namespaces = { names = [cfg.namespace] } }]
      relabel_configs = concat(
        [{ source_labels = ["__meta_kubernetes_pod_container_port_name"], action = "keep", regex = cfg.port }],
        local.scrape_common_relabels,
      )
    }
  }

  # What gets published to CloudWatch (namespace hw/Prometheus). Anything not matched is dropped.
  emf_metric_declaration = [
    # App: request count by route/status and latency sum/count (avg latency per route).
    {
      source_labels    = ["job"]
      label_matcher    = "^hello-world$"
      dimensions       = [["ClusterName", "route", "code"]]
      metric_selectors = ["^http_requests_total$"]
    },
    {
      source_labels    = ["job"]
      label_matcher    = "^hello-world$"
      dimensions       = [["ClusterName", "route"]]
      metric_selectors = ["^http_request_duration_seconds_(sum|count)$"]
    },
    # Nodes: Linux conntrack table + ENA allowance counters. [ClusterName] for alarms (worst node),
    # [ClusterName, NodeName] for the dashboard.
    {
      source_labels = ["job"]
      label_matcher = "^node-exporter$"
      dimensions    = [["ClusterName"], ["ClusterName", "NodeName"]]
      metric_selectors = [
        "^node_nf_conntrack_entries(_limit)?$",
        "^node_ethtool_(bw_in|bw_out|pps|conntrack|linklocal)_allowance_exceeded$",
        "^node_ethtool_conntrack_allowance_available$",
      ]
    },
    # HPA state for the hw-hpa-* alarms (HPAs are long-lived, so per-HPA dimensions are fine).
    {
      source_labels    = ["job"]
      label_matcher    = "^kube-state-metrics$"
      dimensions       = [["ClusterName", "namespace", "horizontalpodautoscaler"]]
      metric_selectors = ["^kube_horizontalpodautoscaler_(spec_max_replicas|spec_min_replicas|status_current_replicas|status_desired_replicas)$"]
    },
  ]

  cloudwatch_observability_config = {
    containerLogs = {
      enabled = true
      fluentBit = {
        resources = {
          requests = { cpu = "25m", memory = "64Mi" }
          limits   = { cpu = "200m", memory = "200Mi" }
        }
      }
    }
    nodeExporter     = { enabled = false }
    kubeStateMetrics = { enabled = false }

    agents = [
      {
        name = "cloudwatch-agent"
        config = {
          logs = {
            metrics_collected = {
              kubernetes = {
                enhanced_container_insights = true
                accelerated_compute_metrics = false
              }
            }
          }
        }
        resources = {
          requests = { cpu = "50m", memory = "128Mi" }
          limits   = { cpu = "250m", memory = "384Mi" }
        }
      },
      {
        name     = "cloudwatch-agent-prometheus"
        mode     = "deployment"
        replicas = 1
        config = {
          logs = {
            metrics_collected = {
              prometheus = {
                cluster_name           = var.project
                prometheus_config_path = "/etc/prometheusconfig/prometheus.yaml"
                emf_processor = {
                  metric_namespace   = "hw/Prometheus"
                  metric_declaration = local.emf_metric_declaration
                }
              }
            }
            force_flush_interval = 30
          }
        }
        prometheus = {
          config = {
            global         = { scrape_interval = "60s", scrape_timeout = "10s" }
            scrape_configs = values(local.scrape_job)
          }
        }
        resources = {
          requests = { cpu = "25m", memory = "96Mi" }
          limits   = { cpu = "200m", memory = "256Mi" }
        }
      },
    ]
  }
}

# Fluent Bit / Container Insights would otherwise create these on first write with no KMS key
# and infinite retention. Pre-creating them keeps logs encrypted (data CMK) and bounded.
resource "aws_cloudwatch_log_group" "container_insights" {
  #checkov:skip=CKV_AWS_338:14-day retention is a deliberate cost choice for a demo on a $100/month account (GAPS)
  for_each = toset(["application", "dataplane", "host", "performance"])

  name              = "/aws/containerinsights/${var.project}/${each.key}"
  retention_in_days = var.log_retention_days
  kms_key_id        = local.p.data_kms_key_arn
}
