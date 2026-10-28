module "network" {
  source = "../modules/network"

  name     = var.project
  cidr     = var.vpc_cidr
  az_count = 2
  # One NAT per AZ: losing an AZ no longer breaks egress for the other (+~$33/mo for the 2nd NAT).
  single_nat_gateway = false
  log_retention_days = var.log_retention_days
  logs_kms_key_arn   = aws_kms_key.data.arn
}

module "aurora" {
  source = "../modules/aurora-serverless"

  name                   = var.project
  engine_version         = var.aurora_engine_version
  parameter_group_family = var.aurora_parameter_group_family
  # 0.5 ACU floor (the smallest non-zero value): always warm, no ~15 s resume on the first request
  # after idle. Costs ~$1.45/day; power.py down still stops the cluster when not in use.
  min_acu              = 0.5
  max_acu              = 2
  database_name        = "hello"
  kms_key_arn          = aws_kms_key.data.arn
  vpc_id               = module.network.vpc_id
  db_subnet_group_name = module.network.database_subnet_group_name
  log_retention_days   = var.log_retention_days
}

module "ecr_hello_world" {
  source = "../modules/ecr-repository"

  name        = "hello-world"
  kms_key_arn = aws_kms_key.data.arn
}
