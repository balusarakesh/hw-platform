# Public hosted zone for the app's domain. The domain itself is registered at an external
# registrar (Route 53 Domains registration isn't available on this account; see GAPS), and its
# NS records there point at the name servers output below.
#
# Lives in bootstrap so it exists (and delegation can propagate) before the persistent stack
# requests the ACM certificate, which needs DNS validation to resolve.

variable "domain" {
  description = "Domain registered at an external registrar and delegated to this zone."
  type        = string
  default     = "test-hw-app.click"
}

resource "aws_route53_zone" "main" {
  name    = var.domain
  comment = "${var.project}: delegated from the external registrar"

  # Deleting the zone breaks delegation; recreating it gets new name servers.
  lifecycle {
    prevent_destroy = true
  }
}

output "name_servers" {
  description = "Set these as the domain's name servers at the registrar."
  value       = aws_route53_zone.main.name_servers
}
