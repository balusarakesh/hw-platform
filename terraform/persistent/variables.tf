variable "aws_profile" {
  description = "Local AWS CLI profile Terraform authenticates with."
  type        = string
  default     = "default"
}

variable "region" {
  description = "AWS region."
  type        = string
  default     = "us-east-2"
}

variable "project" {
  description = "Name prefix."
  type        = string
  default     = "hw"
}

variable "domain" {
  description = "Domain whose hosted zone the bootstrap stack created."
  type        = string
  default     = "test-hw-app.click"
}

variable "vpc_cidr" {
  description = "VPC CIDR (/16)."
  type        = string
  default     = "10.20.0.0/16"
}

variable "aurora_engine_version" {
  description = "Aurora PostgreSQL engine version."
  type        = string
  default     = "18.6"
}

variable "aurora_parameter_group_family" {
  description = "Parameter group family for aurora_engine_version."
  type        = string
  default     = "aurora-postgresql18"
}

variable "log_retention_days" {
  description = "Default CloudWatch Logs retention."
  type        = number
  default     = 14
}
