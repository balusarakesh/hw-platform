provider "aws" {
  profile = var.aws_profile
  region  = var.region

  default_tags {
    tags = local.tags
  }
}

# Auth comes from GITHUB_TOKEN in the environment (export GITHUB_TOKEN=$(gh auth token)).
# Never stored in code or state. Only this stack talks to GitHub, and only from a laptop.
provider "github" {
  owner = var.github_owner
}

locals {
  tags = {
    project    = var.project
    owner      = var.github_owner
    managed-by = "terraform"
    stack      = "bootstrap"
  }
}

data "aws_caller_identity" "current" {}
