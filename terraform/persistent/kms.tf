# One customer-managed key for the data layer: RDS storage + master secret, ECR images,
# CloudWatch log groups and the alerts SNS topic. (EKS Secrets get their own key in the cluster stack.)
# IAM in this account controls who may use it; the extra statements let AWS services that
# don't act through IAM principals (Logs, CloudWatch alarms -> SNS) use it.

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
}

data "aws_iam_policy_document" "data_key" {
  # In a key policy, resources = ["*"] means "this key", not every resource.
  #checkov:skip=CKV_AWS_111:Key policy; "*" is scoped to this key
  #checkov:skip=CKV_AWS_356:Key policy; "*" is scoped to this key
  #checkov:skip=CKV_AWS_109:Key policy; account root admin is the AWS-recommended default
  statement {
    sid       = "AccountAdmin"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${local.account_id}:root"]
    }
  }

  statement {
    sid = "CloudWatchLogs"
    actions = [
      "kms:Encrypt*",
      "kms:Decrypt*",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:Describe*",
    ]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["logs.${var.region}.amazonaws.com"]
    }
    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:${local.partition}:logs:${var.region}:${local.account_id}:log-group:*"]
    }
  }

  statement {
    sid       = "CloudWatchAlarmsToEncryptedSns"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey*"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_kms_key" "data" {
  description             = "${var.project} data layer (RDS, ECR, logs, SNS)"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.data_key.json
}

resource "aws_kms_alias" "data" {
  name          = "alias/${var.project}-data"
  target_key_id = aws_kms_key.data.key_id
}
