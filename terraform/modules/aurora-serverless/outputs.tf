output "cluster_id" {
  value = module.aurora.cluster_id
}

output "cluster_arn" {
  value = module.aurora.cluster_arn
}

# Needed to build rds-db:connect ARNs: arn:aws:rds-db:<region>:<acct>:dbuser:<resource_id>/<db_user>
output "cluster_resource_id" {
  value = module.aurora.cluster_resource_id
}

output "endpoint" {
  value = module.aurora.cluster_endpoint
}

output "port" {
  value = module.aurora.cluster_port
}

output "database_name" {
  value = module.aurora.cluster_database_name
}

output "master_username" {
  value = module.aurora.cluster_master_username
}

output "master_user_secret_arn" {
  value = module.aurora.cluster_master_user_secret[0].secret_arn
}

output "security_group_id" {
  value = module.aurora.security_group_id
}
