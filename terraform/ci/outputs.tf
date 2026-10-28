output "cosign_key_arn" {
  value = aws_kms_key.cosign.arn
}

output "cosign_key_alias" {
  value = aws_kms_alias.cosign.name
}

output "push_runner_role_arn" {
  value = module.pod_identity_push_runner.iam_role_arn
}
