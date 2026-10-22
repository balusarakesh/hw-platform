module "network" {
  source = "../modules/network"

  name               = var.project
  cidr               = var.vpc_cidr
  az_count           = 2
  single_nat_gateway = true
  log_retention_days = var.log_retention_days
  logs_kms_key_arn   = aws_kms_key.data.arn
}

module "aurora" {
  source = "../modules/aurora-serverless"

  name                   = var.project
  engine_version         = var.aurora_engine_version
  parameter_group_family = var.aurora_parameter_group_family
  min_acu                = 0
  max_acu                = 2
  database_name          = "hello"
  kms_key_arn            = aws_kms_key.data.arn
  vpc_id                 = module.network.vpc_id
  db_subnet_group_name   = module.network.database_subnet_group_name
  log_retention_days     = var.log_retention_days
}

module "ecr_hello_world" {
  source = "../modules/ecr-repository"

  name        = "hello-world"
  kms_key_arn = aws_kms_key.data.arn
}
