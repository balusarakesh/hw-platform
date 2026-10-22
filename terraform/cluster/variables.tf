variable "aws_profile" {
  description = "Local AWS CLI profile Terraform authenticates with."
  type        = string
  default     = "default"
}

variable "region" {
  description = "AWS region."
  type        = string
  default     = "us-west-2"
}

variable "project" {
  description = "Name prefix; also the EKS cluster name."
  type        = string
  default     = "hw"
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version."
  type        = string
  default     = "1.37"
}

variable "node_instance_type" {
  description = "Managed node group instance type (arm64/Graviton)."
  type        = string
  default     = "t4g.medium"
}

variable "node_desired_size" {
  description = "Initial node count. Later changes come from power.py / autoscaling (the module ignores drift)."
  type        = number
  default     = 2
}

variable "github_repo_url" {
  description = "Repo ArgoCD syncs from."
  type        = string
  default     = "https://github.com/balusarakesh/hw-platform.git"
}

variable "argocd_chart_version" {
  description = "argo-cd Helm chart version (must match gitops/helmfile.yaml)."
  type        = string
  default     = "10.10.5"
}

variable "argocd_apps_chart_version" {
  description = "argocd-apps Helm chart version (root Application)."
  type        = string
  default     = "2.0.7"
}

variable "app_db_user" {
  description = "Postgres user the app logs in as via IAM auth."
  type        = string
  default     = "hw_app"
}

variable "log_retention_days" {
  description = "Retention for the control plane log group."
  type        = number
  default     = 14
}
