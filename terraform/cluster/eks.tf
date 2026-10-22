# Home IP allowlist for the public API endpoint. Set by hand in SSM and marked sensitive
# so it never shows up in plans, Atlantis comments or outputs. Format: "1.2.3.4/32[,5.6.7.8/32]".
data "aws_ssm_parameter" "admin_cidrs" {
  name = "/${var.project}/admin_cidrs"
}

locals {
  admin_cidrs = sensitive(split(",", data.aws_ssm_parameter.admin_cidrs.value))
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.29.0"

  name               = var.project
  kubernetes_version = var.kubernetes_version

  vpc_id                   = local.p.vpc_id
  subnet_ids               = local.p.private_subnet_ids
  control_plane_subnet_ids = local.p.private_subnet_ids

  # Private endpoint for nodes and in-cluster tools; public endpoint only from my IP.
  endpoint_private_access      = true
  endpoint_public_access       = true
  endpoint_public_access_cidrs = local.admin_cidrs

  # Access entries (EKS API) instead of the aws-auth ConfigMap.
  authentication_mode                      = "API"
  enable_cluster_creator_admin_permissions = true

  # Kubernetes Secrets are envelope-encrypted with a CMK the module creates.
  encryption_config = {
    resources = ["secrets"]
  }

  enabled_log_types                      = ["api", "audit", "authenticator"]
  cloudwatch_log_group_retention_in_days = var.log_retention_days
  cloudwatch_log_group_kms_key_id        = local.p.data_kms_key_arn

  # IRSA: the module registers the cluster's OIDC issuer with IAM.
  enable_irsa = true

  addons = {
    vpc-cni = {
      before_compute = true
      configuration_values = jsonencode({
        # Prefix delegation lifts the t4g.medium pod limit from 17 to 110.
        env = {
          ENABLE_PREFIX_DELEGATION = "true"
          WARM_PREFIX_TARGET       = "1"
        }
        # Enforce Kubernetes NetworkPolicies natively (no Calico needed).
        enableNetworkPolicy = "true"
      })
    }
    coredns    = {}
    kube-proxy = {}
    # Detects node health issues (kernel, network, runtime) and feeds node auto repair.
    eks-node-monitoring-agent = {}
  }

  eks_managed_node_groups = {
    general = {
      ami_type       = "AL2023_ARM_64_STANDARD"
      instance_types = [var.node_instance_type]

      # min 0 lets power.py scale to zero; the module ignores desired_size drift.
      min_size     = 0
      max_size     = 3
      desired_size = var.node_desired_size

      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 30
            volume_type           = "gp3"
            encrypted             = true # AWS-managed aws/ebs key
            delete_on_termination = true
          }
        }
      }

      # IMDSv2 only, hop limit 1: pods can't reach the node's instance role via IMDS.
      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required"
        http_put_response_hop_limit = 1
      }

      node_repair_config = {
        enabled = true
      }

      update_config = {
        max_unavailable = 1
      }

      labels = {
        role = "general"
      }
    }
  }

  # Karpenter will look for this tag on the node SG (subnets are tagged in the network module).
  node_security_group_tags = {
    "karpenter.sh/discovery" = var.project
  }
}

# RDS only accepts Postgres from the EKS nodes (pods share the node SG with the VPC CNI).
resource "aws_vpc_security_group_ingress_rule" "rds_from_nodes" {
  security_group_id            = local.p.aurora_security_group_id
  referenced_security_group_id = module.eks.node_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = local.p.aurora_port
  to_port                      = local.p.aurora_port
  description                  = "Postgres from EKS nodes"
}

# Nodes only need to reach RDS on 5432 inside the VPC, nothing wider.
resource "aws_vpc_security_group_egress_rule" "nodes_to_rds" {
  security_group_id            = module.eks.node_security_group_id
  referenced_security_group_id = local.p.aurora_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = local.p.aurora_port
  to_port                      = local.p.aurora_port
  description                  = "Postgres to Aurora"
}
