# Aurora PostgreSQL Serverless v2, single writer, scale-to-zero, IAM auth, TLS enforced.
# The security group starts with no ingress; callers add rules for their clients
# (the cluster stack allows the EKS node SG), which avoids a persistent<->cluster cycle.

terraform {
  required_version = ">= 1.17.0, < 2.0.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
  }
}

module "aurora" {
  source  = "terraform-aws-modules/rds-aurora/aws"
  version = "10.4.1"

  name           = var.name
  engine         = "aurora-postgresql"
  engine_version = var.engine_version
  engine_mode    = "provisioned" # Serverless v2 is "provisioned" + db.serverless instances

  cluster_instance_class = "db.serverless"
  instances = {
    writer = {}
  }

  serverlessv2_scaling_configuration = {
    min_capacity = var.min_acu # 0 = auto-pause when idle; first query after a pause waits ~15s
    max_capacity = var.max_acu
    # Only meaningful when min_capacity = 0.
    seconds_until_auto_pause = var.min_acu == 0 ? var.seconds_until_auto_pause : null
  }

  database_name   = var.database_name
  master_username = var.master_username

  # RDS generates the master password and keeps it in Secrets Manager; it is never in state.
  manage_master_user_password   = true
  master_user_secret_kms_key_id = var.kms_key_arn

  # Apps log in with short-lived IAM tokens instead of passwords.
  iam_database_authentication_enabled = true

  storage_encrypted = true
  kms_key_id        = var.kms_key_arn

  vpc_id                 = var.vpc_id
  db_subnet_group_name   = var.db_subnet_group_name
  create_db_subnet_group = false
  create_security_group  = true
  security_group_name    = "${var.name}-aurora"
  # No ingress here on purpose; see header comment.
  security_group_ingress_rules = {}

  cluster_parameter_group = {
    name   = "${var.name}-aurora-pg"
    family = var.parameter_group_family
    parameters = [
      # Reject any non-TLS connection.
      { name = "rds.force_ssl", value = "1", apply_method = "pending-reboot" }, # static parameter
      # PG 18: a list of connection stages to log, no longer on/off.
      { name = "log_connections", value = "all" },
    ]
  }

  backup_retention_period   = var.backup_retention_days
  preferred_backup_window   = "07:00-08:00"
  copy_tags_to_snapshot     = true
  deletion_protection       = var.deletion_protection
  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.name}-final"
  apply_immediately         = true

  # Free tier (7-day retention): query-level load/wait analysis for debugging slow requests.
  cluster_performance_insights_enabled          = true
  cluster_performance_insights_kms_key_id       = var.kms_key_arn
  cluster_performance_insights_retention_period = 7

  enabled_cloudwatch_logs_exports        = ["postgresql"]
  create_cloudwatch_log_group            = true
  cloudwatch_log_group_retention_in_days = var.log_retention_days
  cloudwatch_log_group_kms_key_id        = var.kms_key_arn

  tags = var.tags
}
