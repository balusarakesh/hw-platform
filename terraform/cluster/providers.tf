provider "aws" {
  profile = var.aws_profile
  region  = var.region

  default_tags {
    tags = {
      project    = var.project
      owner      = "balusarakesh"
      managed-by = "terraform"
      stack      = "cluster"
    }
  }
}

# Short-lived token from `aws eks get-token`; nothing cluster-related is written to disk.
provider "helm" {
  kubernetes = {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region, "--profile", var.aws_profile]
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
}

# Bucket name is deterministic (see bootstrap/state.tf), so no extra config is needed here.
data "terraform_remote_state" "persistent" {
  backend = "s3"
  config = {
    bucket  = "${var.project}-tfstate-${local.account_id}-${var.region}"
    key     = "persistent/terraform.tfstate"
    region  = var.region
    profile = var.aws_profile
  }
}

locals {
  p = data.terraform_remote_state.persistent.outputs
}
