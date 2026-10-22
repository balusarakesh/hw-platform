terraform {
  required_version = ">= 1.17.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "= 6.70.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "= 3.3.0"
    }
  }

  backend "s3" {
    key = "cluster/terraform.tfstate"
  }
}
