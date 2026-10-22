terraform {
  required_version = ">= 1.17.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "= 6.70.0"
    }
    github = {
      source  = "integrations/github"
      version = "= 6.13.0"
    }
  }

  # Partial config: bucket/region come from terraform/backend.hcl (generated, gitignored).
  # First run uses a local backend override; see README "Bootstrap".
  backend "s3" {
    key = "bootstrap/terraform.tfstate"
  }
}
