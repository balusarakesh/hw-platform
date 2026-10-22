variable "aws_profile" {
  description = "Local AWS CLI profile Terraform authenticates with."
  type        = string
  default     = "default"
}

variable "region" {
  description = "AWS region for every regional resource in this project."
  type        = string
  default     = "us-east-2"
}

variable "project" {
  description = "Short name used as a prefix for resource names."
  type        = string
  default     = "hw"
}

variable "github_owner" {
  description = "GitHub user that owns the repo."
  type        = string
  default     = "balusarakesh"
}

variable "github_repo" {
  description = "Name of the (public) monorepo."
  type        = string
  default     = "hw-platform"
}

variable "monthly_budget_usd" {
  description = "Monthly AWS Budget (matches the account's hard spend limit); alerts go to SSM /hw/alert_email."
  type        = number
  default     = 100
}
