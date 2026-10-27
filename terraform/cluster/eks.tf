# Home IP allowlist for the public API endpoint. Set by hand in SSM and marked sensitive
# so it never shows up in plans, Atlantis comments or outputs. Format: "1.2.3.4/32[,5.6.7.8/32]".
data "aws_ssm_parameter" "admin_cidrs" {
  name = "/${var.project}/admin_cidrs"
}

locals {
  admin_cidrs = sensitive(split(",", data.aws_ssm_parameter.admin_cidrs.value))
}

# Addon versions are pinned (most_recent = false) so new eksbuild releases don't show up as surprise
# diffs in every Atlantis plan; bump them here deliberately (aws eks describe-addon-versions).
locals {
  addon_versions = {
    "vpc-cni"                         = "v1.23.2-eksbuild.8"
    "eks-pod-identity-agent"          = "v1.4.1-eksbuild.3"
    "coredns"                         = "v1.14.7-eksbuild.22"
    "kube-proxy"                      = "v1.36.0-eksbuild.58"
    "metrics-server"                  = "v0.9.0-eksbuild.14"
    "eks-node-monitoring-agent"       = "v1.7.5-eksbuild.1"
    "amazon-cloudwatch-observability" = "v6.7.0-eksbuild.1"
  }
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

  # No IRSA: it needs an IAM OIDC provider, which the account's SCP denies. Pod Identity instead.
  enable_irsa = false

  addons = {
    vpc-cni = {
      addon_version  = local.addon_versions["vpc-cni"]
      most_recent    = false
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
    # Node agent that hands pods their IAM credentials (Pod Identity).
    eks-pod-identity-agent = {
      addon_version  = local.addon_versions["eks-pod-identity-agent"]
      most_recent    = false
      before_compute = true
    }
    coredns = {
      addon_version = local.addon_versions["coredns"]
      most_recent   = false
    }
    kube-proxy = {
      addon_version = local.addon_versions["kube-proxy"]
      most_recent   = false
    }
    # Resource metrics API (CPU/memory) that the HorizontalPodAutoscaler reads.
    metrics-server = {
      addon_version = local.addon_versions["metrics-server"]
      most_recent   = false
    }
    # Detects node health issues (kernel, network, runtime) and feeds node auto repair.
    eks-node-monitoring-agent = {
      addon_version = local.addon_versions["eks-node-monitoring-agent"]
      most_recent   = false
    }

    # Container Insights (enhanced) + Fluent Bit -> CloudWatch Logs, plus a second CloudWatch agent
    # (Deployment, 1 replica) that scrapes Prometheus endpoints and publishes an allowlist as EMF.
    amazon-cloudwatch-observability = {
      addon_version = local.addon_versions["amazon-cloudwatch-observability"]
      most_recent   = false
      pod_identity_association = [{
        role_arn        = module.pod_identity_cloudwatch_observability.iam_role_arn
        service_account = "cloudwatch-agent"
      }]
      configuration_values = jsonencode(local.cloudwatch_observability_config)
    }
  }

  eks_managed_node_groups = {
    general = {
      ami_type       = "AL2023_ARM_64_STANDARD"
      instance_types = [var.node_instance_type]

      # min 0 lets power.py scale to zero; Cluster Autoscaler moves between 1..max while running.
      # The module ignores desired_size drift, so neither fights Terraform.
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
