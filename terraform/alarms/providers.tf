# Applied after the first ArgoCD sync: the ALB is created by the AWS Load Balancer Controller
# (IngressGroup "hw"), so it only exists once the app is deployed. The ALB is long-lived (power-off
# keeps it), so this stack only needs re-applying if the IngressGroup is recreated.

provider "aws" {
  profile = var.aws_profile == "" ? null : var.aws_profile
  region  = var.region

  default_tags {
    tags = {
      project    = var.project
      owner      = "balusarakesh"
      managed-by = "terraform"
      stack      = "alarms"
    }
  }
}

data "aws_caller_identity" "current" {}

locals {
  state_bucket = "${var.project}-tfstate-${data.aws_caller_identity.current.account_id}-${var.region}"
}

data "terraform_remote_state" "persistent" {
  backend = "s3"
  config = {
    bucket  = local.state_bucket
    key     = "persistent/terraform.tfstate"
    region  = var.region
    profile = var.aws_profile == "" ? null : var.aws_profile
  }
}

data "terraform_remote_state" "cluster" {
  backend = "s3"
  config = {
    bucket  = local.state_bucket
    key     = "cluster/terraform.tfstate"
    region  = var.region
    profile = var.aws_profile == "" ? null : var.aws_profile
  }
}

# The controller tags every ALB it creates with its IngressGroup name.
data "aws_lb" "hw" {
  tags = {
    "ingress.k8s.aws/stack" = var.ingress_group
  }
}

# Node instance type comes from the live node group, and its network/CPU specs from the EC2 API,
# so thresholds follow an instance-type change without editing variables.
data "aws_eks_node_group" "general" {
  cluster_name    = data.terraform_remote_state.cluster.outputs.cluster_name
  node_group_name = split(":", data.terraform_remote_state.cluster.outputs.node_group_name)[1]
}

data "aws_ec2_instance_type" "node" {
  instance_type = one(data.aws_eks_node_group.general.instance_types)
}

locals {
  node_instance_type = data.aws_ec2_instance_type.node.instance_type
  # Sustained (baseline) bandwidth of the default network card, Gbps.
  node_baseline_bandwidth_gbps = one([
    for c in data.aws_ec2_instance_type.node.network_cards : c.baseline_bandwidth
    if c.index == data.aws_ec2_instance_type.node.default_network_card_index
  ])
  # kube-proxy sizes nf_conntrack_max as max(32768 * vCPUs, 131072) (its --conntrack-* defaults).
  node_conntrack_limit = max(32768 * data.aws_ec2_instance_type.node.default_vcpus, 131072)
}

locals {
  p            = data.terraform_remote_state.persistent.outputs
  cluster_name = data.terraform_remote_state.cluster.outputs.cluster_name
  alb          = data.aws_lb.hw.arn_suffix
  actions      = [local.p.alerts_topic_arn]
}
