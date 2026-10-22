# The hosted zone is created by the bootstrap stack (the domain is registered at an external
# registrar and delegated to it). Looked up here so this stack can never destroy it.
data "aws_route53_zone" "main" {
  name         = var.domain
  private_zone = false
}

# One cert for the apex + any subdomain (app., atlantis.). Lives here so it outlives the cluster.
resource "aws_acm_certificate" "main" {
  domain_name               = var.domain
  subject_alternative_names = ["*.${var.domain}"]
  validation_method         = "DNS"
  key_algorithm             = "EC_prime256v1"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "acm_validation" {
  # apex and wildcard share one validation record, so de-duplicate by record name.
  for_each = {
    for dvo in aws_acm_certificate.main.domain_validation_options : dvo.resource_record_name => dvo...
  }

  zone_id         = data.aws_route53_zone.main.zone_id
  name            = each.value[0].resource_record_name
  type            = each.value[0].resource_record_type
  records         = [each.value[0].resource_record_value]
  ttl             = 300
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "main" {
  certificate_arn         = aws_acm_certificate.main.arn
  validation_record_fqdns = [for r in aws_route53_record.acm_validation : r.fqdn]
}
