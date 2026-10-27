# Terraform -> GitOps hand-off. Helm values need ARNs/IDs that only Terraform knows; instead of
# hard-coding them (and the account ID) in a public repo, they're published here and the
# helmfile plugin reads them with `fetchSecretValue "ref+awsssm://..."` at render time.
# None of these are secrets; the sensitive params (/hw/admin_cidrs, /hw/alert_email) live
# outside /hw/gitops/ so the repo-server role can't read them.

# Terraform state location, for Atlantis' `terraform init -backend-config=...` (the laptop uses the
# gitignored terraform/backend.hcl instead). The key ARN is resolved from the bootstrap alias.
data "aws_kms_alias" "tfstate" {
  name = "alias/${var.project}-tfstate"
}

locals {
  gitops_params = {
    region               = var.region
    cluster_name         = module.eks.cluster_name
    vpc_id               = local.p.vpc_id
    domain               = local.p.domain
    app_host             = "app.${local.p.domain}"
    hosted_zone_id       = local.p.hosted_zone_id
    acm_certificate_arn  = local.p.acm_certificate_arn
    ecr_repository_url   = local.p.ecr_repository_url
    db_host              = local.p.aurora_endpoint
    db_port              = tostring(local.p.aurora_port)
    db_name              = local.p.aurora_database_name
    db_app_user          = var.app_db_user
    db_master_username   = local.p.aurora_master_username
    db_master_secret_arn = local.p.aurora_master_secret_arn
    waf_acl_arn          = local.p.waf_acl_arn
    atlantis_host        = "atlantis.${local.p.domain}"
    tfstate_bucket       = "${var.project}-tfstate-${local.account_id}-${var.region}"
    tfstate_kms_key_arn  = data.aws_kms_alias.tfstate.target_key_arn
  }
}

resource "aws_ssm_parameter" "gitops" {
  for_each = local.gitops_params

  name  = "/${var.project}/gitops/${each.key}"
  type  = "String"
  value = each.value
}
