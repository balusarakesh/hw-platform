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

locals {
  p            = data.terraform_remote_state.persistent.outputs
  cluster_name = data.terraform_remote_state.cluster.outputs.cluster_name
  alb          = data.aws_lb.hw.arn_suffix
  actions      = [local.p.alerts_topic_arn]
}
