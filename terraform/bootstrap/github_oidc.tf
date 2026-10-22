# GitHub Actions -> AWS without stored keys: workflows exchange their OIDC token for short-lived creds.

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

locals {
  ecr_repo_arn = "arn:${data.aws_partition.current.partition}:ecr:${var.region}:${data.aws_caller_identity.current.account_id}:repository/hello-world"
}

data "aws_iam_policy_document" "ecr_push_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    # Only workflows running on main of this repo; PR branches and forks can't push images.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_owner}/${var.github_repo}:ref:refs/heads/main"]
    }
  }
}

data "aws_iam_policy_document" "ecr_push" {
  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    sid = "PushHelloWorld"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImages",
      "ecr:DescribeImageScanFindings",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = [local.ecr_repo_arn]
  }
}

resource "aws_iam_role" "github_ecr_push" {
  name                 = "${var.project}-github-ecr-push"
  assume_role_policy   = data.aws_iam_policy_document.ecr_push_trust.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy" "github_ecr_push" {
  name   = "ecr-push-hello-world"
  role   = aws_iam_role.github_ecr_push.id
  policy = data.aws_iam_policy_document.ecr_push.json
}

# Role ARN is not secret; exposing it as an Actions variable keeps account IDs out of workflow files.
resource "github_actions_variable" "ecr_push_role" {
  repository    = github_repository.this.name
  variable_name = "AWS_ECR_PUSH_ROLE_ARN"
  value         = aws_iam_role.github_ecr_push.arn
}

resource "github_actions_variable" "aws_region" {
  repository    = github_repository.this.name
  variable_name = "AWS_REGION"
  value         = var.region
}
