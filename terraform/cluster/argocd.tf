# Chicken-and-egg breaker: Terraform installs ArgoCD once, plus a single root Application.
# From then on ArgoCD owns everything in gitops/, including its own chart (gitops/apps/argocd/),
# so Terraform ignores later changes to these two releases.

resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = "argocd"
  create_namespace = true
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.argocd_chart_version

  # Same values ArgoCD uses to manage itself, so the hand-over is a no-op.
  values = [file("${path.module}/../../gitops/apps/argocd/values.yaml")]

  lifecycle {
    ignore_changes = all
  }

  depends_on = [module.eks, aws_ssm_parameter.gitops, module.pod_identity_argocd_repo_server]
}

resource "helm_release" "argocd_root_app" {
  name       = "argocd-root"
  namespace  = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = var.argocd_apps_chart_version

  values = [yamlencode({
    applications = {
      root = {
        namespace  = "argocd"
        project    = "default"
        finalizers = ["resources-finalizer.argocd.argoproj.io"]
        source = {
          repoURL        = var.github_repo_url
          targetRevision = "main"
          path           = "gitops/apps"
          # Each apps/<name>/ folder holds application.yaml (a manifest) and values.yaml (Helm values,
          # read by helmfile). Only the Application manifests are applied.
          directory = {
            recurse = true
            include = "*/application.yaml"
          }
        }
        destination = {
          server    = "https://kubernetes.default.svc"
          namespace = "argocd"
        }
        syncPolicy = {
          automated = {
            prune    = true
            selfHeal = true
          }
        }
      }
    }
  })]

  lifecycle {
    ignore_changes = all
  }

  depends_on = [helm_release.argocd]
}
