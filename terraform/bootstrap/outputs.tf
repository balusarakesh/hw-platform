output "state_bucket" {
  value = aws_s3_bucket.state.bucket
}

output "state_kms_key_arn" {
  value = aws_kms_key.state.arn
}

# Paste into terraform/backend.hcl (gitignored): `terraform output -raw backend_hcl > ../backend.hcl`
output "backend_hcl" {
  value = <<-EOT
    bucket       = "${aws_s3_bucket.state.bucket}"
    region       = "${var.region}"
    profile      = "${var.aws_profile}"
    encrypt      = true
    kms_key_id   = "${aws_kms_key.state.arn}"
    use_lockfile = true
  EOT
}

output "repo_url" {
  value = github_repository.this.html_url
}
