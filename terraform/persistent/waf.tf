# AWS WAF on the app's ALB. Attached by the AWS Load Balancer Controller through the Ingress
# annotation alb.ingress.kubernetes.io/wafv2-acl-arn (ARN handed over via SSM /hw/gitops/waf_acl_arn),
# so the controller-owned ALB stays fully managed from GitOps.
#
# Rules, in evaluation order:
#   0  per-IP rate limit: more than var.rate_limit_per_minute requests in 60s -> 429 (10 RPS = 600)
#   5  atlantis.<domain> only from GitHub's webhook IP ranges (https://api.github.com/meta `hooks`) -> 403
#   10 AWS managed Common rule set (OWASP-style: XSS, LFI, bad bots, oversized bodies, ...)
#   20 AWS managed Known Bad Inputs (Log4Shell, Spring4Shell, ...)
# Anything not blocked is allowed.

variable "rate_limit_per_minute" {
  description = "Requests per client IP per 60s before WAF answers 429 (10 RPS = 600)."
  type        = number
  default     = 600
}

# GitHub publishes the source ranges of webhook deliveries. Read at plan time, so a change on
# GitHub's side shows up as a diff on the next plan.
data "http" "github_meta" {
  url = "https://api.github.com/meta"
  request_headers = {
    Accept = "application/vnd.github+json"
  }
}

locals {
  github_hook_cidrs = jsondecode(data.http.github_meta.response_body).hooks
  atlantis_host     = "atlantis.${var.domain}"
}

resource "aws_wafv2_ip_set" "github_hooks_v4" {
  name               = "${var.project}-github-hooks-v4"
  scope              = "REGIONAL"
  ip_address_version = "IPV4"
  addresses          = [for c in local.github_hook_cidrs : c if !strcontains(c, ":")]
}

resource "aws_wafv2_ip_set" "github_hooks_v6" {
  name               = "${var.project}-github-hooks-v6"
  scope              = "REGIONAL"
  ip_address_version = "IPV6"
  addresses          = [for c in local.github_hook_cidrs : c if strcontains(c, ":")]
}

resource "aws_wafv2_web_acl" "app" {
  name        = "${var.project}-app"
  description = "Rate limiting + AWS managed rules for the hello-world ALB"
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  custom_response_body {
    key          = "rate_limited"
    content_type = "APPLICATION_JSON"
    content      = jsonencode({ error = "rate limit exceeded, slow down" })
  }

  rule {
    name     = "rate-limit-per-ip"
    priority = 0

    action {
      block {
        custom_response {
          response_code            = 429
          custom_response_body_key = "rate_limited"
          response_header {
            name  = "Retry-After"
            value = "60"
          }
        }
      }
    }

    statement {
      rate_based_statement {
        limit                 = var.rate_limit_per_minute
        evaluation_window_sec = 60
        aggregate_key_type    = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "rate-limit-per-ip"
      sampled_requests_enabled   = true
    }
  }

  # Atlantis' webhook endpoint shares the ALB with the app. Only GitHub may reach it: block any
  # request for atlantis.<domain> whose source IP isn't in GitHub's hook ranges.
  rule {
    name     = "atlantis-github-only"
    priority = 5

    action {
      block {}
    }

    statement {
      and_statement {
        statement {
          byte_match_statement {
            search_string         = local.atlantis_host
            positional_constraint = "EXACTLY"
            field_to_match {
              single_header {
                name = "host"
              }
            }
            text_transformation {
              priority = 0
              type     = "LOWERCASE"
            }
          }
        }
        statement {
          not_statement {
            statement {
              or_statement {
                statement {
                  ip_set_reference_statement {
                    arn = aws_wafv2_ip_set.github_hooks_v4.arn
                  }
                }
                statement {
                  ip_set_reference_statement {
                    arn = aws_wafv2_ip_set.github_hooks_v6.arn
                  }
                }
              }
            }
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "atlantis-github-only"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "aws-common"
    priority = 10

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesCommonRuleSet"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "aws-common"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "aws-known-bad-inputs"
    priority = 20

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "aws-known-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.project}-app"
    sampled_requests_enabled   = true
  }
}

# WAF requires the destination log group name to start with "aws-waf-logs-".
resource "aws_cloudwatch_log_group" "waf" {
  #checkov:skip=CKV_AWS_338:14-day retention is a deliberate cost choice for a demo on a $100/month account (GAPS)
  name              = "aws-waf-logs-${var.project}-app"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.data.arn
}

resource "aws_wafv2_web_acl_logging_configuration" "app" {
  resource_arn            = aws_wafv2_web_acl.app.arn
  log_destination_configs = [aws_cloudwatch_log_group.waf.arn]

  # Only log what WAF acted on (blocks/429s); allowed traffic is already in the app's access logs.
  logging_filter {
    default_behavior = "DROP"
    filter {
      behavior    = "KEEP"
      requirement = "MEETS_ANY"
      condition {
        action_condition {
          action = "BLOCK"
        }
      }
    }
  }
}

output "waf_acl_arn" {
  value = aws_wafv2_web_acl.app.arn
}
