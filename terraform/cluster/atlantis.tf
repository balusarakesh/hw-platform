# Atlantis runs `terraform plan/apply` for the persistent, cluster and alarms stacks from inside the
# cluster. Its Pod Identity role is the most privileged identity in this setup:
#
#   - AdministratorAccess, because those stacks create IAM roles/policies, KMS keys, EKS, RDS, VPC,
#     WAF... A tighter policy would have to enumerate every action the modules use and grows with them.
#   - Blast radius: anyone who can get code into a planned PR (terraform plan can run arbitrary code
#     through providers/external data) or exec into the Atlantis pod has account admin. Mitigations
#     here: same-repo PRs only (no forks), repo allowlist, apply only when the PR is mergeable,
#     webhook secret + WAF allowing only GitHub's hook IPs. Harder options are in docs/GAPS.md
#     (plan-only role on PRs, permission boundary, Atlantis outside the cluster it manages).
#   - bootstrap (state bucket, GitHub repo) is never run by Atlantis.

module "pod_identity_atlantis" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "2.10.0"

  name            = "${var.project}-atlantis"
  use_name_prefix = false

  additional_policy_arns = {
    admin = "arn:${local.partition}:iam::aws:policy/AdministratorAccess"
  }

  associations = {
    this = {
      cluster_name    = module.eks.cluster_name
      namespace       = "atlantis"
      service_account = "atlantis"
    }
  }
}

# The cluster stack's helm provider talks to the Kubernetes API, so the Atlantis role also needs
# cluster-admin there. Defined outside module.eks: the role depends on the cluster (association),
# so putting it in the module's access_entries would create a cycle.
resource "aws_eks_access_entry" "atlantis" {
  cluster_name  = module.eks.cluster_name
  principal_arn = module.pod_identity_atlantis.iam_role_arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "atlantis_admin" {
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_eks_access_entry.atlantis.principal_arn
  policy_arn    = "arn:${local.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }
}
