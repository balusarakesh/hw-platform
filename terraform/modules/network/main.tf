# Opinionated VPC: public subnets only for the ALB + NAT, private subnets for nodes/pods,
# isolated database subnets with no route to the internet at all.

terraform {
  required_version = ">= 1.17.0, < 2.0.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  # /16 split: public /24s, private /20s (room for prefix-delegated pod IPs), database /24s.
  public_subnets   = [for i, _ in local.azs : cidrsubnet(var.cidr, 8, i)]
  private_subnets  = [for i, _ in local.azs : cidrsubnet(var.cidr, 4, i + 1)]
  database_subnets = [for i, _ in local.azs : cidrsubnet(var.cidr, 8, 200 + i)]
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.7.3"

  name = var.name
  cidr = var.cidr
  azs  = local.azs

  public_subnets   = local.public_subnets
  private_subnets  = local.private_subnets
  database_subnets = local.database_subnets

  enable_dns_hostnames = true
  enable_dns_support   = true

  # One NAT for the whole VPC: ~$33/mo instead of ~$66. Trade-off: an AZ outage breaks egress (GAPS).
  enable_nat_gateway     = true
  single_nat_gateway     = var.single_nat_gateway
  one_nat_gateway_per_az = !var.single_nat_gateway

  # Database subnets: own route table, no IGW/NAT route, own subnet group for RDS.
  create_database_subnet_group           = true
  create_database_subnet_route_table     = true
  create_database_internet_gateway_route = false
  create_database_nat_gateway_route      = false

  # Public subnets never auto-assign public IPs; only the ALB/NAT get them explicitly.
  map_public_ip_on_launch = false

  # Tags the AWS Load Balancer Controller uses to pick subnets.
  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }

  # Lock down the default SG / NACL so nothing accidentally uses them.
  manage_default_security_group  = true
  default_security_group_ingress = []
  default_security_group_egress  = []

  enable_flow_log                                 = true
  create_flow_log_cloudwatch_log_group            = true
  create_flow_log_cloudwatch_iam_role             = true
  flow_log_traffic_type                           = "REJECT"
  flow_log_max_aggregation_interval               = 600
  flow_log_cloudwatch_log_group_retention_in_days = var.log_retention_days
  flow_log_cloudwatch_log_group_kms_key_id        = var.logs_kms_key_arn

  tags = var.tags
}
