# The public monorepo and its security settings, managed as code.
# Things the provider cannot do (creating a GitHub App, fork-PR workflow approval) are in docs/GAPS.md.
# No GitHub OIDC -> AWS role: the account SCP denies IAM OIDC providers (docs/GAPS.md).

resource "github_repository" "this" {
  name        = var.github_repo
  description = "Incode SRE take-home: EKS + Aurora + GitOps hello-world platform"
  visibility  = "public"

  has_issues             = true
  has_wiki               = false
  has_projects           = false
  delete_branch_on_merge = true
  allow_merge_commit     = false
  allow_rebase_merge     = false
  allow_squash_merge     = true

  security_and_analysis {
    secret_scanning {
      status = "enabled"
    }
    secret_scanning_push_protection {
      status = "enabled"
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "github_repository_vulnerability_alerts" "this" {
  repository = github_repository.this.name
  enabled    = true
}

resource "github_repository_dependabot_security_updates" "this" {
  repository = github_repository.this.name
  enabled    = true

  depends_on = [github_repository_vulnerability_alerts.this]
}

# GITHUB_TOKEN is read-only by default; workflows opt in to more via `permissions:`.
resource "github_workflow_repository_permissions" "this" {
  repository                       = github_repository.this.name
  default_workflow_permissions     = "read"
  can_approve_pull_request_reviews = false
}

# main: no force-push, no deletion, changes land via PR with checks.
# Approvals are 0 because GitHub won't let the sole contributor approve their own PR (see GAPS).
resource "github_repository_ruleset" "main" {
  name        = "protect-main"
  repository  = github_repository.this.name
  target      = "branch"
  enforcement = "active"

  conditions {
    ref_name {
      include = ["~DEFAULT_BRANCH"]
      exclude = []
    }
  }

  # Repo admin (me) can bypass, needed for the initial push and break-glass fixes.
  bypass_actors {
    actor_id    = 5 # built-in "Repository admin" role
    actor_type  = "RepositoryRole"
    bypass_mode = "always"
  }

  rules {
    deletion         = true
    non_fast_forward = true

    pull_request {
      required_approving_review_count = 0
      dismiss_stale_reviews_on_push   = true
    }
  }
}

# Region isn't secret; workflows read it from here instead of hard-coding it.
resource "github_actions_variable" "aws_region" {
  repository    = github_repository.this.name
  variable_name = "AWS_REGION"
  value         = var.region
}

# ECR repo URL for the publish job in .github/workflows/app.yml (not secret; keeps the account ID
# out of workflow files). Looked up, because the repo is created by the persistent stack.
data "aws_ecr_repository" "hello_world" {
  name = "hello-world"
}

resource "github_actions_variable" "ecr_repository_url" {
  repository    = github_repository.this.name
  variable_name = "ECR_REPOSITORY_URL"
  value         = data.aws_ecr_repository.hello_world.repository_url
}
