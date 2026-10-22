# Consumed by the cluster stack via terraform_remote_state.

output "region" {
  value = var.region
}

output "domain" {
  value = var.domain
}

output "vpc_id" {
  value = module.network.vpc_id
}

output "vpc_cidr" {
  value = module.network.vpc_cidr
}

output "private_subnet_ids" {
  value = module.network.private_subnet_ids
}

output "public_subnet_ids" {
  value = module.network.public_subnet_ids
}

output "data_kms_key_arn" {
  value = aws_kms_key.data.arn
}

output "hosted_zone_id" {
  value = data.aws_route53_zone.main.zone_id
}

output "hosted_zone_arn" {
  value = data.aws_route53_zone.main.arn
}

output "acm_certificate_arn" {
  value = aws_acm_certificate_validation.main.certificate_arn
}

output "aurora_cluster_id" {
  value = module.aurora.cluster_id
}

output "aurora_cluster_resource_id" {
  value = module.aurora.cluster_resource_id
}

output "aurora_endpoint" {
  value = module.aurora.endpoint
}

output "aurora_port" {
  value = module.aurora.port
}

output "aurora_database_name" {
  value = module.aurora.database_name
}

output "aurora_master_username" {
  value = module.aurora.master_username
}

output "aurora_master_secret_arn" {
  value = module.aurora.master_user_secret_arn
}

output "aurora_security_group_id" {
  value = module.aurora.security_group_id
}

output "ecr_repository_url" {
  value = module.ecr_hello_world.url
}

output "ecr_repository_arn" {
  value = module.ecr_hello_world.arn
}

output "alerts_topic_arn" {
  value = aws_sns_topic.alerts.arn
}
