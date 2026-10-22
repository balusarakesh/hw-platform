# One IAM role per Kubernetes service account. Each trust policy pins the exact
# namespace:serviceaccount, so no other pod can assume it.

locals {
  oidc = {
    this = {
      provider_arn = module.eks.oidc_provider_arn
    }
  }
  irsa_defaults = {
    use_name_prefix = false
  }
}

module "irsa_aws_load_balancer_controller" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "6.8.2"

  name            = "${var.project}-aws-load-balancer-controller"
  use_name_prefix = local.irsa_defaults.use_name_prefix

  attach_load_balancer_controller_policy = true

  oidc_providers = {
    this = merge(local.oidc.this, {
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    })
  }
}

module "irsa_external_dns" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "6.8.2"

  name            = "${var.project}-external-dns"
  use_name_prefix = local.irsa_defaults.use_name_prefix

  # Only the one hosted zone, not every zone in the account.
  attach_external_dns_policy    = true
  external_dns_hosted_zone_arns = [local.p.hosted_zone_arn]

  oidc_providers = {
    this = merge(local.oidc.this, {
      namespace_service_accounts = ["external-dns:external-dns"]
    })
  }
}

# The app: can log in to Postgres as exactly one DB user. Nothing else.
module "irsa_hello_world" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "6.8.2"

  name            = "${var.project}-hello-world"
  use_name_prefix = local.irsa_defaults.use_name_prefix

  permissions = {
    RdsIamConnect = {
      actions   = ["rds-db:connect"]
      resources = ["arn:${local.partition}:rds-db:${var.region}:${local.account_id}:dbuser:${local.p.aurora_cluster_resource_id}/${var.app_db_user}"]
    }
  }

  oidc_providers = {
    this = merge(local.oidc.this, {
      namespace_service_accounts = ["hello-world:hello-world"]
    })
  }
}

# DB bootstrap Job: reads the RDS-managed master secret to create the IAM-auth app user and schema.
# Separate SA + role so the app itself never holds master credentials.
module "irsa_db_bootstrap" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "6.8.2"

  name            = "${var.project}-db-bootstrap"
  use_name_prefix = local.irsa_defaults.use_name_prefix

  permissions = {
    ReadMasterSecret = {
      actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
      resources = [local.p.aurora_master_secret_arn]
    }
    DecryptMasterSecret = {
      actions   = ["kms:Decrypt"]
      resources = [local.p.data_kms_key_arn]
      condition = [{
        test     = "StringEquals"
        variable = "kms:ViaService"
        values   = ["secretsmanager.${var.region}.amazonaws.com"]
      }]
    }
  }

  oidc_providers = {
    this = merge(local.oidc.this, {
      namespace_service_accounts = ["hello-world:hello-world-db-bootstrap"]
    })
  }
}

# ArgoCD repo-server's helmfile plugin reads Terraform outputs from SSM (/hw/gitops/*) at render time.
module "irsa_argocd_repo_server" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "6.8.2"

  name            = "${var.project}-argocd-repo-server"
  use_name_prefix = local.irsa_defaults.use_name_prefix

  permissions = {
    ReadGitopsParams = {
      actions   = ["ssm:GetParameter", "ssm:GetParameters"]
      resources = ["arn:${local.partition}:ssm:${var.region}:${local.account_id}:parameter/${var.project}/gitops/*"]
    }
  }

  oidc_providers = {
    this = merge(local.oidc.this, {
      namespace_service_accounts = ["argocd:argocd-repo-server"]
    })
  }
}
