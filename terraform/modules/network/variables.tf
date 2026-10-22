variable "name" {
  description = "VPC name."
  type        = string
}

variable "cidr" {
  description = "VPC CIDR; must be a /16 for the subnet math in main.tf."
  type        = string
  default     = "10.20.0.0/16"

  validation {
    condition     = endswith(var.cidr, "/16")
    error_message = "cidr must be a /16."
  }
}

variable "az_count" {
  description = "Number of AZs (EKS and RDS both need at least 2)."
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2
    error_message = "EKS and RDS subnet groups need at least 2 AZs."
  }
}

variable "single_nat_gateway" {
  description = "true = one shared NAT (cheap), false = one per AZ (resilient)."
  type        = bool
  default     = true
}

variable "log_retention_days" {
  description = "Retention for the VPC flow log group."
  type        = number
  default     = 14
}

variable "logs_kms_key_arn" {
  description = "KMS key for the flow log group."
  type        = string
}

variable "tags" {
  description = "Extra tags."
  type        = map(string)
  default     = {}
}
