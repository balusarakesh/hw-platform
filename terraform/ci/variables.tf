variable "aws_profile" {
  description = "Local AWS CLI profile; \"\" (Atlantis) uses the default credential chain instead."
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

variable "push_runner_namespace" {
  description = "Namespace of the ARC scale set that pushes and signs images (push-to-main jobs only)."
  type        = string
  default     = "arc-runners-push"
}

variable "push_runner_service_account" {
  description = "Service account the push runner pods run as (Pod Identity binds the role to it)."
  type        = string
  default     = "hw-runners-push"
}
