# aws_profile = "" (Atlantis) means: no named profile, use the default credential chain.
provider "aws" {
  profile = var.aws_profile == "" ? null : var.aws_profile
  region  = var.region

  default_tags {
    tags = {
      project    = var.project
      owner      = "balusarakesh"
      managed-by = "terraform"
      stack      = "persistent"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
