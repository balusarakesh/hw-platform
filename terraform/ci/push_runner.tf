# Identity of the push runners (ARC scale set hw-runners-push, used only by push-to-main jobs in
# .github/workflows/app.yml). GitHub Actions can't get AWS credentials directly (the account SCP
# blocks IAM OIDC providers), so the AWS-touching job runs in-cluster with this Pod Identity role:
# push to the one ECR repo and sign with the cosign key. Nothing else.

module "pod_identity_push_runner" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "2.10.0"

  name            = "${var.project}-ci-push"
  use_name_prefix = false

  attach_custom_policy = true
  policy_statements = [
    {
      sid       = "EcrLogin"
      actions   = ["ecr:GetAuthorizationToken"]
      resources = ["*"]
    },
    {
      sid = "PushHelloWorld"
      actions = [
        "ecr:BatchCheckLayerAvailability",
        "ecr:BatchGetImage",
        "ecr:CompleteLayerUpload",
        "ecr:DescribeImages",
        "ecr:GetDownloadUrlForLayer",
        "ecr:InitiateLayerUpload",
        "ecr:PutImage",
        "ecr:UploadLayerPart",
      ]
      resources = [data.terraform_remote_state.persistent.outputs.ecr_repository_arn]
    },
    {
      sid       = "CosignSign"
      actions   = ["kms:Sign", "kms:GetPublicKey", "kms:DescribeKey"]
      resources = [aws_kms_key.cosign.arn]
    },
  ]

  associations = {
    this = {
      cluster_name    = data.terraform_remote_state.cluster.outputs.cluster_name
      namespace       = var.push_runner_namespace
      service_account = var.push_runner_service_account
    }
  }
}
