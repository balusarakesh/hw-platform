# EKS Pod Identity: one IAM role per Kubernetes service account.
#
# Why not IRSA: IRSA needs the cluster's OIDC issuer registered as an IAM OIDC provider, and this
# account's guardrail SCP denies all iam:*OpenIDConnectProvider actions (docs/GAPS.md). Pod Identity
# doesn't need one: roles trust pods.eks.amazonaws.com, and the namespace/serviceaccount pairing is an
# EKS association managed here, so no role ARN annotations are needed in the Helm charts.

module "pod_identity_aws_load_balancer_controller" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "2.10.0"

  name            = "${var.project}-aws-load-balancer-controller"
  use_name_prefix = false

  attach_aws_lb_controller_policy = true

  associations = {
    this = {
      cluster_name    = module.eks.cluster_name
      namespace       = "kube-system"
      service_account = "aws-load-balancer-controller"
    }
  }
}

module "pod_identity_external_dns" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "2.10.0"

  name            = "${var.project}-external-dns"
  use_name_prefix = false

  # Only the one hosted zone, not every zone in the account.
  attach_external_dns_policy    = true
  external_dns_hosted_zone_arns = [local.p.hosted_zone_arn]

  associations = {
    this = {
      cluster_name    = module.eks.cluster_name
      namespace       = "external-dns"
      service_account = "external-dns"
    }
  }
}

module "pod_identity_cluster_autoscaler" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "2.10.0"

  name            = "${var.project}-cluster-autoscaler"
  use_name_prefix = false

  # Scaling actions are limited to ASGs tagged for this cluster.
  attach_cluster_autoscaler_policy = true
  cluster_autoscaler_cluster_names = [module.eks.cluster_name]

  associations = {
    this = {
      cluster_name    = module.eks.cluster_name
      namespace       = "kube-system"
      service_account = "cluster-autoscaler"
    }
  }
}

# The app: can log in to Postgres as exactly one DB user. Nothing else.
module "pod_identity_hello_world" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "2.10.0"

  name            = "${var.project}-hello-world"
  use_name_prefix = false

  attach_custom_policy = true
  policy_statements = [{
    sid       = "RdsIamConnect"
    actions   = ["rds-db:connect"]
    resources = ["arn:${local.partition}:rds-db:${var.region}:${local.account_id}:dbuser:${local.p.aurora_cluster_resource_id}/${var.app_db_user}"]
  }]

  associations = {
    this = {
      cluster_name    = module.eks.cluster_name
      namespace       = "hello-world"
      service_account = "hello-world"
    }
  }
}

# DB bootstrap Job: reads the RDS-managed master secret to create the IAM-auth app user and schema.
# Separate SA + role so the app itself never holds master credentials.
module "pod_identity_db_bootstrap" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "2.10.0"

  name            = "${var.project}-db-bootstrap"
  use_name_prefix = false

  attach_custom_policy = true
  policy_statements = [
    {
      sid       = "ReadMasterSecret"
      actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
      resources = [local.p.aurora_master_secret_arn]
    },
    {
      sid       = "DecryptMasterSecret"
      actions   = ["kms:Decrypt"]
      resources = [local.p.data_kms_key_arn]
      condition = [{
        test     = "StringEquals"
        variable = "kms:ViaService"
        values   = ["secretsmanager.${var.region}.amazonaws.com"]
      }]
    },
  ]

  associations = {
    this = {
      cluster_name    = module.eks.cluster_name
      namespace       = "hello-world"
      service_account = "hello-world-db-bootstrap"
    }
  }
}

# ArgoCD repo-server's helmfile plugin reads Terraform outputs from SSM (/hw/gitops/*) at render time.
module "pod_identity_argocd_repo_server" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "2.10.0"

  name            = "${var.project}-argocd-repo-server"
  use_name_prefix = false

  attach_custom_policy = true
  policy_statements = [{
    sid       = "ReadGitopsParams"
    actions   = ["ssm:GetParameter", "ssm:GetParameters"]
    resources = ["arn:${local.partition}:ssm:${var.region}:${local.account_id}:parameter/${var.project}/gitops/*"]
  }]

  associations = {
    this = {
      cluster_name    = module.eks.cluster_name
      namespace       = "argocd"
      service_account = "argocd-repo-server"
    }
  }
}

# CloudWatch agent + Fluent Bit (amazon-cloudwatch-observability addon): write Container Insights
# metrics, Prometheus-scraped metrics (EMF) and container logs. The association is made by the addon
# itself (eks.tf: pod_identity_association), so this role has no associations here.
module "pod_identity_cloudwatch_observability" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "2.10.0"

  name            = "${var.project}-cloudwatch-observability"
  use_name_prefix = false

  attach_aws_cloudwatch_observability_policy = true
}
