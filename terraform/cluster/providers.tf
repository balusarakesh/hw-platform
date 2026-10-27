# aws_profile = "" (Atlantis) means: no named profile, use the default credential chain
# (Atlantis gets credentials from its Pod Identity role).
provider "aws" {
  profile = var.aws_profile == "" ? null : var.aws_profile
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

# Short-lived EKS token from an ephemeral resource: never written to state or plan files, and
# no `aws` CLI needed (the Atlantis image doesn't ship one).
ephemeral "aws_eks_cluster_auth" "this" {
  name = module.eks.cluster_name
}

provider "helm" {
  kubernetes = {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    token                  = ephemeral.aws_eks_cluster_auth.this.token
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
    profile = var.aws_profile == "" ? null : var.aws_profile
  }
}

locals {
  p = data.terraform_remote_state.persistent.outputs
}
