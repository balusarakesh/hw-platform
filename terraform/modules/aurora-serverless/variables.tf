variable "name" {
  description = "Cluster identifier / name prefix."
  type        = string
}

variable "engine_version" {
  description = "Aurora PostgreSQL version (scale-to-zero needs 16.3+)."
  type        = string
}

variable "parameter_group_family" {
  description = "Parameter group family matching engine_version, e.g. aurora-postgresql18."
  type        = string
}

variable "min_acu" {
  description = "Minimum ACUs; 0 enables auto-pause."
  type        = number
  default     = 0
}

variable "max_acu" {
  description = "Maximum ACUs."
  type        = number
  default     = 2
}

variable "seconds_until_auto_pause" {
  description = "Idle seconds before pausing (min_acu = 0 only)."
  type        = number
  default     = 600
}

variable "database_name" {
  description = "Initial database name."
  type        = string
}

variable "master_username" {
  description = "Master user (password is RDS-managed in Secrets Manager)."
  type        = string
  default     = "hw_admin"
}

variable "kms_key_arn" {
  description = "CMK for storage, master secret and log group."
  type        = string
}

variable "vpc_id" {
  description = "VPC for the security group."
  type        = string
}

variable "db_subnet_group_name" {
  description = "Existing DB subnet group (isolated database subnets)."
  type        = string
}

variable "backup_retention_days" {
  description = "Automated backup retention."
  type        = number
  default     = 7
}

variable "deletion_protection" {
  description = "Block accidental deletes."
  type        = bool
  default     = true
}

variable "log_retention_days" {
  description = "Retention for the postgresql log group."
  type        = number
  default     = 14
}

variable "tags" {
  description = "Extra tags."
  type        = map(string)
  default     = {}
}
