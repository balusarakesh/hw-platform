# cosign signing key. Asymmetric (ECC P-256, SIGN_VERIFY): the private half never leaves KMS; CI signs
# by calling kms:Sign, and the cluster verifies with the public key (published to SSM below).
# Asymmetric keys don't support automatic rotation; rotating means a new key + re-signing.

data "aws_iam_policy_document" "cosign_key" {
  # In a key policy, resources = ["*"] means "this key".
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
}

resource "aws_kms_key" "cosign" {
  #checkov:skip=CKV_AWS_7:Rotation isn't supported for asymmetric signing keys
  description              = "${var.project} cosign image signing key"
  customer_master_key_spec = "ECC_NIST_P256"
  key_usage                = "SIGN_VERIFY"
  deletion_window_in_days  = 30
  policy                   = data.aws_iam_policy_document.cosign_key.json
}

resource "aws_kms_alias" "cosign" {
  name          = "alias/${var.project}-cosign"
  target_key_id = aws_kms_key.cosign.key_id
}

data "aws_kms_public_key" "cosign" {
  key_id = aws_kms_key.cosign.arn
}

# Public key for the in-cluster signature check (gitops reads it with ref+awsssm). Not a secret.
resource "aws_ssm_parameter" "cosign_public_key" {
  name  = "/${var.project}/gitops/cosign_public_key"
  type  = "String"
  value = data.aws_kms_public_key.cosign.public_key_pem
}
