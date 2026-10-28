# hw-platform

Incode SRE take-home: a Go **hello-world** app on **EKS**, reading from **Aurora PostgreSQL Serverless v2** with IAM
database auth, delivered end to end through **GitOps** (Atlantis for Terraform, ArgoCD + helmfile for Kubernetes),
secure by default and observable (logs, metrics, traces, alarms).

> **Live:** https://app.app-test-hw.click · **Docs:** [architecture](docs/architecture.md) ·
> [interview cheat sheet](docs/interview-cheatsheet.md) · [slides](docs/presentation.md) ·
> [demo walkthrough](docs/walkthrough.md) · [gaps & trade-offs](docs/GAPS.md)
>
> The AWS account's guardrails (SCPs) shaped several choices: region `us-east-2`, **EKS Pod Identity** instead of
> IRSA, **Cluster Autoscaler** instead of Karpenter, no GitHub Actions OIDC. See [GAPS](docs/GAPS.md).

## Architecture (summary)

```
Internet ─▶ AWS WAF (10 RPS/IP → 429, managed rules) ─▶ ALB (ACM, TLS 1.3) ─▶ hello-world pods (target-type ip)
                                                     └▶ atlantis.<domain>/events (GitHub hook IPs only)
VPC 10.20.0.0/16, 2 AZs: public (ALB, NAT×2) · private (EKS 1.36, m7g.medium) · isolated DB subnets (no internet)
hello-world ─▶ Aurora PostgreSQL 18 (0.5–2 ACU) over TLS verify-full with 15-min IAM tokens, from its own pod SG
```
Diagrams for runtime, identity, delivery and observability: [docs/architecture.md](docs/architecture.md).

## Repository layout

| Path | What |
|---|---|
| `app/` | Go app (`serve` + `migrate`), OpenTelemetry tracing, Prometheus metrics, SQL schema/seed, Dockerfile |
| `terraform/bootstrap/` | State bucket, Route 53 zone, GitHub repo + rulesets, AWS Budget — **laptop-only** |
| `terraform/persistent/` | VPC (NAT per AZ), Aurora, ECR, KMS, ACM, SNS, WAF |
| `terraform/cluster/` | EKS, node group, addons, Pod Identity roles, pod security group, ArgoCD bootstrap, SSM hand-off |
| `terraform/alarms/` | CloudWatch alarms (incl. per-node multi-time-series) + `hw-overview` dashboard |
| `terraform/ci/` | cosign KMS signing key, push-runner and Kyverno ECR roles |
| `terraform/modules/` | `network`, `aurora-serverless`, `ecr-repository` |
| `gitops/apps/<app>/` | One ArgoCD `application.yaml` + Helm `values.yaml` per app (16 apps) |
| `gitops/charts/` | `hello-world`, `network-policies`, `image-policies`, `arc-runners` |
| `.github/workflows/` | `app.yml` (test → build → scan → push → sign → bump PR), `gitops-diff.yml`, `terraform-scan.yml` |
| `scripts/` | `power.py` (on/off), `push-image.sh`, `argocd-pr-diff-token.sh` |
| `atlantis.yaml` | Atlantis projects: `persistent`, `cluster`, `alarms`, `ci` (serial plans) |

## How changes flow (all via PRs)

| Change in | PR gets | On merge |
|---|---|---|
| `terraform/**` | Atlantis plan comment; `atlantis apply` once mergeable (required checks pass) | merged after apply |
| `gitops/**` | `argocd app diff` comment from an in-cluster runner (ArgoCD stays private) | ArgoCD syncs |
| `app/**` | `go vet`/test/lint, arm64 image build, trivy scan (required checks) | CI builds → ECR → cosign sign (KMS) → opens an image-bump PR |

`main` is PR-only (no force-push/delete), with required checks. `bootstrap` is applied from the laptop by design.

## Security baseline

| Requirement | How |
|---|---|
| Least privilege, no static creds | One **Pod Identity** role per service account (app: `rds-db:connect` as one DB user only). No IAM users/keys in cluster or CI. |
| Private network | Nodes/pods private, Aurora in isolated subnets; only ALB + NAT public. **Security groups for pods**: only `hw-app-pods` may reach Aurora. **NetworkPolicies** default-deny in every namespace we own (42 policies). EKS API: private + IP-restricted public. IMDSv2, hop limit 1. |
| Encryption at rest | KMS: Aurora, master secret, ECR, CloudWatch Logs, SNS, Kubernetes Secrets (envelope), Terraform state; EBS encrypted. |
| Encryption in transit | ALB TLS 1.3 policy, HSTS, HTTP→HTTPS redirect; app→Aurora `verify-full`, `rds.force_ssl=1`. |
| Secrets | RDS-managed master password; app uses IAM tokens; ESO syncs GitHub App/ArgoCD tokens from Secrets Manager. Nothing in Git (scanned). |
| Workloads | Non-root, read-only rootfs, no privilege escalation, caps dropped, seccomp, limits; **PSA `restricted` enforced** on every namespace we own except `node-exporter`. Images pinned by digest; **cosign-signed and verified at admission** (Kyverno). |
| Edge | **AWS WAF**: 10 RPS per IP → 429, AWS Common + Known Bad Inputs → 403, Atlantis host GitHub-IPs only. |

**Documented exceptions:** EKS public endpoint (operator IP only); AWS-managed addons run privileged (CNI, kube-proxy,
Pod Identity agent, node monitoring, CloudWatch agent, Fluent Bit — expected); node-exporter uses host namespaces
(non-root, no caps); Atlantis has AdministratorAccess (hardening plan in GAPS); operator laptop uses the account's
`admin` key.

## Observability

- **Logs**: Fluent Bit → CloudWatch (KMS, 14 days); one JSON access-log line per request with `trace_id`.
- **Metrics**: Container Insights (enhanced), app RED metrics, node conntrack, ENA allowances, HPA state.
- **Traces**: OpenTelemetry (HTTP + DB spans) → CloudWatch agent → **X-Ray**.
- **Alarms** (24, → SNS email): RPS > 10/s, latency, 5xx, unhealthy targets, pods crashloop/pending/unavailable,
  HPA at max, node NotReady / at max / status check, per-node network & conntrack (multi-time-series), ENA,
  control-plane P99/5xx/429, Aurora ACU, WAF 429s. Dashboard: `hw-overview`.

## Scaling & resilience

HPA 2–6 replicas · Cluster Autoscaler (managed node group, max 4) · **VPA** (in-place resize) for ArgoCD ·
ALB **pod readiness gates** + preStop + deregistration delay (0 errors deleting pods under load) · PDBs ·
topology spread · node auto repair · NAT per AZ · Aurora 0.5 ACU floor (no cold start), 7-day backups.

## Deploy from scratch

1. Register a domain; set SSM `/hw/alert_email` and `/hw/admin_cidrs` (SecureString).
2. `export GITHUB_TOKEN=$(gh auth token) && make bootstrap`; point the registrar's NS at
   `terraform -chdir=terraform/bootstrap output name_servers`.
3. Laptop applies once (later changes go through Atlantis): `persistent` → first image (`make image`) → `cluster` → `ci` → `alarms`.
4. Create the GitHub App (manual; see GAPS), store `hw/github/app` + `hw/github/webhook-secret` in Secrets Manager,
   run `scripts/argocd-pr-diff-token.sh`.
5. ArgoCD syncs everything in `gitops/apps/`.

ArgoCD UI: `kubectl -n argocd port-forward svc/argocd-server 8080:443` (password: `argocd-initial-admin-secret`).

## Power off / on

```bash
scripts/.venv/bin/python scripts/power.py status
scripts/.venv/bin/python scripts/power.py down --yes   # alarms off, pause CA auto-sync, drain + nodes→0, stop Aurora (parallel)
scripts/.venv/bin/python scripts/power.py up --yes     # Aurora + nodes back, CA + auto-sync on, app check, alarms on
```

## Cost (us-east-2, approximate)

| | ~$/day |
|---|---|
| EKS control plane | 2.40 |
| NAT gateways ×2 (+ IPs) | 2.40 |
| 3 × m7g.medium | 2.95 |
| Aurora 0.5 ACU floor | 1.45 |
| ALB + WAF | 0.85 |
| KMS, Route 53, Secrets, CloudWatch | ~0.50 |
| **Running** | **~10.50** |
| **Powered down** (`power.py down`: nodes + Aurora off) | **~6.10** |

Budget: $100/month (account hard limit) with alerts at 50/75/90 % — keep it powered down when idle.

## Threat model (short)

| If compromised | Can reach |
|---|---|
| App pod | Aurora as `hw_app` (SELECT); its OTLP/DNS paths; nothing else in AWS |
| ArgoCD | cluster-admin in Kubernetes; AWS: read `/hw/gitops/*` |
| Atlantis | AdministratorAccess — the biggest blast radius (see GAPS) |
| PR diff runner | read-only ArgoCD API; no AWS role, no Kubernetes token |
| Push runner (main only) | ECR push to one repo + `kms:Sign` with the cosign key |
