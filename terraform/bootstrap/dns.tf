# Public hosted zone for the app's domain. The domain itself is registered at an external
# registrar (Route 53 Domains registration isn't available on this account; see GAPS), and its
# NS records there point at the name servers output below.
#
# Lives in bootstrap so it exists (and delegation can propagate) before the persistent stack
# requests the ACM certificate, which needs DNS validation to resolve.

variable "domain" {
  description = "Domain registered at an external registrar and delegated to this zone."
  type        = string
  default     = "app-test-hw.click"
}

resource "aws_route53_zone" "main" {
  name    = var.domain
  comment = "${var.project}: delegated from the external registrar"

  # Changing var.domain replaces the zone (new name servers to set at the registrar). The old zone
  # still holds external-dns and ACM validation records, so allow deleting it with them.
  force_destroy = true
}

output "name_servers" {
  description = "Set these as the domain's name servers at the registrar."
  value       = aws_route53_zone.main.name_servers
}
