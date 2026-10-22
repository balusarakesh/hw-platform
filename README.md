# hw-platform

Incode SRE take-home: a Go **hello-world** app on **EKS**, reading from **Aurora PostgreSQL Serverless v2** with
IAM database auth, deployed by **ArgoCD + helmfile**, all provisioned with **Terraform** and secure by default.

> Status: **Phase 1 (baseline)** written and validated locally (not yet applied to AWS). Observability, CI/CD,
> PR diffs, Atlantis and extras follow in later phases. Known gaps and trade-offs: [docs/GAPS.md](docs/GAPS.md).
>
> The AWS account's guardrails (SCPs) shape several choices: region `us-east-2`, **EKS Pod Identity** instead of
> IRSA, **Cluster Autoscaler** instead of Karpenter, and no GitHub Actions OIDC. See
> [docs/GAPS.md#account-guardrails-scps-on-the-aws-account](docs/GAPS.md#account-guardrails-scps-on-the-aws-account).

## Architecture

```
                 Internet
                    │ 443 (80 → 301 to 443)
          ┌─────────▼──────────┐   public subnets (ALB + NAT only)
          │ ALB (ACM TLS 1.3)  │◄── app.test-hw-app.click (Route 53, external-dns)
          └─────────┬──────────┘
                    │ pod IPs (target-type ip)
 ┌──────────────────▼─────────────────────────────┐ private subnets
 │ EKS (private + IP-restricted public endpoint)  │
 │  managed node group: 2–3 × t4g.medium (arm64)  │
 │  ├─ hello-world (2 replicas, Pod Identity → rds-db:connect as hw_app only)
 │  ├─ db-bootstrap Job (Pod Identity → read RDS master secret)
 │  ├─ ArgoCD (+ helmfile plugin sidecar, Pod Identity → read SSM /hw/gitops/*)
 │  ├─ aws-load-balancer-controller, external-dns, cluster-autoscaler (Pod Identity, scoped)
 └──────────────────┬─────────────────────────────┘
                    │ 5432, TLS (rds.force_ssl), IAM token auth
 ┌──────────────────▼─────────────────┐ isolated database subnets (no internet route)
 │ Aurora PostgreSQL 18 Serverless v2 │ 0–2 ACU (auto-pause), KMS-encrypted
 └────────────────────────────────────┘
```

## Repository layout

| Path | What |
|---|---|
| `app/` | Go app (`serve` + `migrate` subcommands), SQL schema/seed, Dockerfile |
| `terraform/bootstrap/` | State bucket (KMS, versioned, S3 lockfile), GitHub repo + settings, AWS Budget ($100, the account's spend limit). Applied from a laptop only |
| `terraform/persistent/` | VPC, NAT, Aurora, ECR, KMS, ACM cert, SNS alerts topic. Changes rarely |
| `terraform/cluster/` | EKS, node group, addons, Pod Identity roles + associations, SSM hand-off params, ArgoCD bootstrap |
| `terraform/modules/` | Reusable wrappers: `network`, `aurora-serverless`, `ecr-repository` |
| `gitops/` | `helmfile.yaml`, the app chart, and `apps/<name>/` per app: `application.yaml` (ArgoCD Application) + `values.yaml` (Helm values) |
| `scripts/` | `push-image.sh` (first image / manual fallback) |
| `docs/GAPS.md` | Known gaps, trade-offs and what I'd do next |

## How the pieces fit

- **Terraform → GitOps hand-off.** Helm values need ARNs/IDs only Terraform knows. The cluster stack writes them to
  SSM (`/hw/gitops/*`); helmfile resolves `ref+awsssm://...` references in the values files at render time. No
  account IDs or ARNs are committed.
- **ArgoCD chicken-and-egg.** Terraform installs ArgoCD and a root `Application` once (`ignore_changes = all`).
  The root app applies every `gitops/apps/*/application.yaml`; `apps/argocd/` makes ArgoCD manage its own chart
  from then on.
- **helmfile in ArgoCD.** ArgoCD has no native helmfile support, so a Config Management Plugin sidecar runs
  `helmfile --selector name=$RELEASE template`. Each `Application` renders exactly one release. Values that only
  Terraform knows are written as `ref+awsssm://hw/gitops/...` strings in plain `values.yaml` files; helmfile
  resolves them (vals) at render time.
- **Autoscaling.** The app has an HPA (2–6 replicas, CPU 70% / memory 80%, metrics-server addon). Cluster
  Autoscaler adds nodes (up to 3) when pods don't fit.
- **IAM for pods.** EKS Pod Identity: each role trusts `pods.eks.amazonaws.com` and is bound to exactly one
  `namespace/serviceaccount` by an association in Terraform, so charts carry no role ARNs.
- **DB access without passwords.** The app's Pod Identity role allows `rds-db:connect` for one DB user. The app mints a
  15-minute IAM token per new connection (pgx `BeforeConnect`) and verifies the server cert against the embedded
  RDS CA (`verify-full`). A PreSync Job with a *separate* role reads the RDS-managed master secret to create that
  user (`GRANT rds_iam`), schema and seed rows; it is idempotent and reruns on each sync.

## Deploy from scratch

Prerequisites: Terraform ≥ 1.17, AWS CLI (profile `default`), `gh`, Docker via Colima, `crane`.

1. **Manual, once:** register the domain at any registrar (Route 53 Domains registration is unavailable on this
   account), then set the two sensitive parameters (never in git):
   ```bash
   aws ssm put-parameter --name /hw/alert_email --type SecureString --value '<email>'
   aws ssm put-parameter --name /hw/admin_cidrs --type SecureString --value "$(curl -s https://checkip.amazonaws.com)/32"
   ```
2. **Bootstrap:** `export GITHUB_TOKEN=$(gh auth token) && make bootstrap`, then set the domain's name servers at
   the registrar to `terraform -chdir=terraform/bootstrap output name_servers` and wait for
   `dig NS test-hw-app.click +short` to return them.
3. **Persistent:** `make plan STACK=persistent && make apply STACK=persistent`
4. **First image:** `colima start --arch aarch64 && make image` (commit the updated image tag/digest in `gitops/apps/hello-world/values.yaml`), push to `main`
5. **Cluster:** `make plan STACK=cluster && make apply STACK=cluster`, then `make kubeconfig`
6. ArgoCD syncs everything; `https://app.test-hw-app.click` serves once the ALB and DNS are up.

ArgoCD UI: `kubectl -n argocd port-forward svc/argocd-server 8443:443` (never exposed publicly).

## Security baseline

| Requirement | How |
|---|---|
| Least-privilege IAM, no static creds | One Pod Identity role per service account, bound to one `namespace/serviceaccount`. No IAM users or access keys are created; GitHub Actions gets no AWS access at all (OIDC is blocked by the account SCP; see GAPS). |
| Private network | Nodes/pods in private subnets, Aurora in isolated subnets (no internet route), only ALB + NAT public. RDS SG allows 5432 from the node SG only. EKS public endpoint limited to my IP. IMDSv2 hop limit 1. |
| Encryption at rest | Aurora storage, master secret, ECR, CloudWatch log groups, SNS: CMK `alias/hw-data`. Kubernetes Secrets: EKS envelope encryption (module-created CMK). Node EBS: encrypted gp3. State: SSE-KMS. |
| Encryption in transit | ALB TLS 1.3/1.2 policy with ACM cert, HTTP → HTTPS redirect, HSTS. App → Aurora TLS `verify-full`, `rds.force_ssl=1`. State bucket denies non-TLS. |
| Secrets | Master password generated + stored by RDS in Secrets Manager; app uses IAM tokens (no password). Alert email / home IP only in SSM SecureString. |
| Workloads | Non-root (uid 65532), read-only rootfs, no privilege escalation, all capabilities dropped, seccomp RuntimeDefault, CPU/memory limits, PSA `restricted` on app namespaces, images pinned by `tag@sha256` (app, ArgoCD, redis, LB controller, external-dns, helmfile sidecar). |
| Remote state | S3 + KMS + versioning + public access block + native S3 locking (`use_lockfile`). |

### Security exceptions (documented)

- **EKS public endpoint** is enabled, restricted to my IP (`/hw/admin_cidrs`). Private-only would need a VPN/bastion.
- **Public GitHub repo** (required by the assignment): Checkov `CKV_GIT_1` skipped.
- **Module pinning by version, not commit hash** (`CKV_TF_1` skipped): registry modules are exact-version pinned and
  provider checksums are locked in `.terraform.lock.hcl` for darwin/linux.
- **`kube-system` has no PSA label**: AWS-managed addons live there.
- More in [docs/GAPS.md](docs/GAPS.md).

## Threat model (short)

- **Exposed:** ALB on 443/80 only. Nothing else is internet-reachable; `/metrics` listens on a separate port that no
  Service or Ingress exposes. ArgoCD is port-forward only.
- **Compromised app pod:** can log in to Postgres as `hw_app` (SELECT only) and nothing else in AWS; IMDS hop limit
  blocks the node role; PSA restricted blocks privilege escalation.
- **Compromised db-bootstrap Job:** master DB credentials (DB admin), no other AWS access.
- **Compromised ArgoCD:** cluster-admin in Kubernetes (it deploys everything); AWS access limited to reading
  `/hw/gitops/*`. Mitigated by keeping it private; next steps in GAPS.
