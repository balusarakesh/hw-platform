terraform {
  required_version = ">= 1.17.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "= 6.70.0"
    }
    http = {
      source  = "hashicorp/http"
      version = "= 3.6.3"
    }
  }

  backend "s3" {
    key = "persistent/terraform.tfstate"
  }
}
