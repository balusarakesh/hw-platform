# CI/CD supply chain: the image-signing key and the identity of the in-cluster runners that push
# and sign images. Its own stack (and Atlantis project) so supply-chain changes are reviewed and
# applied independently of the cluster and data layers.

provider "aws" {
  profile = var.aws_profile == "" ? null : var.aws_profile
  region  = var.region

  default_tags {
    tags = {
      project    = var.project
      owner      = "balusarakesh"
      managed-by = "terraform"
      stack      = "ci"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id   = data.aws_caller_identity.current.account_id
  partition    = data.aws_partition.current.partition
  state_bucket = "${var.project}-tfstate-${local.account_id}-${var.region}"
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
