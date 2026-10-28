# Kyverno's admission controller verifies cosign signatures on hello-world images at pod admission
# (gitops/apps/kyverno + image-policies). It reads the image's signature from ECR, so it gets a
# read-only Pod Identity role for the one repo. The public key comes from SSM (signing.tf); it
# needs no KMS access.
module "pod_identity_kyverno" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "2.10.0"

  name            = "${var.project}-kyverno"
  use_name_prefix = false

  attach_custom_policy = true
  policy_statements = [
    {
      sid       = "EcrLogin"
      actions   = ["ecr:GetAuthorizationToken"]
      resources = ["*"]
    },
    {
      sid = "ReadHelloWorldImagesAndSignatures"
      actions = [
        "ecr:BatchGetImage",
        "ecr:DescribeImages",
        "ecr:GetDownloadUrlForLayer",
        "ecr:ListImages",
      ]
      resources = [data.terraform_remote_state.persistent.outputs.ecr_repository_arn]
    },
  ]

  associations = {
    this = {
      cluster_name    = data.terraform_remote_state.cluster.outputs.cluster_name
      namespace       = "kyverno"
      service_account = "kyverno-admission-controller"
    }
  }
}
