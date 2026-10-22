variable "aws_profile" {
  description = "Local AWS CLI profile Terraform authenticates with."
  type        = string
  default     = "default"
}

variable "region" {
  description = "AWS region."
  type        = string
  default     = "us-east-2"
}

variable "project" {
  description = "Name prefix."
  type        = string
  default     = "hw"
}

variable "ingress_group" {
  description = "ALB IngressGroup name (gitops/charts/hello-world values ingress.groupName)."
  type        = string
  default     = "hw"
}

# --- app / ALB ---------------------------------------------------------------------------

variable "high_rps_threshold" {
  description = "Requests per second that count as 'high' (alarm if sustained for 60s)."
  type        = number
  default     = 10
}

variable "latency_p95_seconds" {
  description = "ALB target response time p95 threshold."
  type        = number
  default     = 1
}

variable "error_rate_percent" {
  description = "Target 5xx as a percentage of requests."
  type        = number
  default     = 5
}

# --- pods / HPA / nodes ------------------------------------------------------------------

variable "hpa_namespace" {
  description = "Namespace of the app's HPA."
  type        = string
  default     = "hello-world"
}

variable "hpa_name" {
  description = "Name of the app's HPA."
  type        = string
  default     = "hello-world"
}

variable "node_group_max_size" {
  description = "Managed node group max_size (terraform/cluster eks.tf); alarm when the cluster sits at it."
  type        = number
  default     = 3
}

# Instance-type specific limits. Source: `aws ec2 describe-instance-types --instance-types t4g.medium`
# (NetworkCards[0].BaselineBandwidthInGbps = 0.256, burst "up to 5 Gigabit"). Change with the instance type.
variable "node_baseline_bandwidth_gbps" {
  description = "Per-node sustained (baseline) network bandwidth in Gbps."
  type        = number
  default     = 0.256
}

variable "node_bandwidth_alarm_percent" {
  description = "Alarm when a node's network throughput exceeds this % of baseline for 5 minutes."
  type        = number
  default     = 80
}

variable "conntrack_table_alarm_percent" {
  description = "Alarm when the Linux conntrack table (nf_conntrack) is this % full on any node."
  type        = number
  default     = 80
}

variable "conntrack_allowance_min_available" {
  description = "Alarm when the ENA tracked-connection allowance left on any node drops below this."
  type        = number
  default     = 5000
}

# --- control plane / DB ------------------------------------------------------------------

variable "apiserver_latency_seconds" {
  description = "EKS API server request latency (vended P99) threshold."
  type        = number
  default     = 3
}

variable "aurora_acu_utilization_percent" {
  description = "Aurora ACUUtilization (% of max_capacity) threshold."
  type        = number
  default     = 80
}

variable "ena_exceeded_per_minute" {
  description = "Cluster-wide ENA allowance-exceeded packets per minute that count as a breaching minute."
  type        = number
  default     = 100
}

variable "rate_limit_per_minute" {
  description = "WAF per-IP rate limit (must match terraform/persistent/waf.tf); used in alarm text."
  type        = number
  default     = 600
}
