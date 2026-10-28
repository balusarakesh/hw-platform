---
marp: true
title: hw-platform — Incode SRE take-home
paginate: true
---

# hw-platform
### Go app on EKS + Aurora, GitOps end to end, secure by default

- Live: https://app.app-test-hw.click
- Repo: https://github.com/balusarakesh/hw-platform
- Docs: `README.md` · `docs/architecture.md` · `docs/GAPS.md` · `docs/walkthrough.md`

---

## What was asked → what's running

| Ask | Delivered |
|---|---|
| VPC, subnets, routing, SGs | 2 AZs; public (ALB/NAT) · private (EKS) · isolated DB subnets; NAT per AZ |
| EKS, managed node group, minimal cost | EKS 1.36, Graviton m7g.medium ×2 (CA up to 4), power on/off script |
| Demo app reachable from internet | Go app behind ALB + ACM + WAF, HPA 2–6 |
| RDS used by the app | Aurora PostgreSQL Serverless v2 via 15-min IAM tokens over TLS |
| Secure by default | Pod Identity, private everything, KMS everywhere, PSA restricted, signed images |
| Going further | Observability (logs, metrics, traces, ~25 alarms), GitOps (Atlantis + ArgoCD PR comments), WAF |

---

## Architecture

See `docs/architecture.md` (runtime, identity, delivery, observability diagrams).

- Edge: WAF (10 RPS/IP → 429, managed rules) → ALB (TLS 1.3) → pods (target-type ip, readiness gates)
- Data: Aurora in isolated subnets; only the app pods' SG may connect; `rds.force_ssl`
- Control: Terraform (4 stacks + ci) → SSM hand-off → ArgoCD/helmfile

---

## Security baseline (pass/fail)

- **IAM**: one Pod Identity role per service account; app can only `rds-db:connect` as `hw_app`
- **No static creds** in cluster/CI (IRSA/GitHub OIDC blocked by SCP → Pod Identity + in-cluster push runner)
- **Network**: private nodes/pods/DB, SG for pods, NetworkPolicies default-deny, EKS API IP-restricted
- **Encryption**: KMS at rest everywhere; TLS ALB + DB `verify-full`; K8s Secrets envelope-encrypted
- **Secrets**: RDS-managed master secret, ESO for GitHub/ArgoCD tokens, nothing in Git (scanned)
- **Workloads**: non-root, read-only fs, no caps, limits, digest-pinned, cosign-verified

---

## What's exposed & blast radius

| Exposed | Protection |
|---|---|
| `app.` 443/80 | WAF rate limit + managed rules, TLS 1.3, HSTS, 80 only redirects |
| `atlantis.` `/events` | WAF: GitHub hook IPs only + HMAC secret; UI never exposed |

| If compromised | Can reach |
|---|---|
| App pod | Aurora as `hw_app` (SELECT); nothing else in AWS (IMDS blocked, no other IAM) |
| ArgoCD | cluster-admin in K8s; AWS: read `/hw/gitops/*` |
| Atlantis | **AdministratorAccess** — biggest risk → hardening plan in GAPS |
| PR runner | read-only ArgoCD API; no AWS role, no K8s token |

---

## Observability (SRE focus)

- **RED metrics** per route, Container Insights, node conntrack + ENA allowances, HPA state
- **Traces**: OpenTelemetry → X-Ray (HTTP + DB spans), trace ID in every access log line
- **Alarms → email**: RPS > 10/s, p95 latency, 5xx, pod health, HPA at max, node health/capacity,
  per-node network limits (multi-time-series), control-plane P99/5xx/429, Aurora, WAF 429s
- **Dashboard** `hw-overview`; every alarm triggered once on purpose (evidence in walkthrough)

---

## GitOps flow (demo)

1. PR touching `terraform/` → **Atlantis plan comment** → `atlantis apply` → merge
2. PR touching `gitops/` → **ArgoCD diff comment** from an in-cluster runner → merge → ArgoCD sync
3. PR touching `app/` → tests + trivy → merge → arm64 image → ECR → cosign sign → **auto bump PR**

---

## Trade-offs I'd defend

- Pod Identity over IRSA (SCP), Cluster Autoscaler over Karpenter (SCP), us-east-2 (SCP)
- Single monorepo (assignment) — multi-repo + versioned modules is the fix
- Public plan/diff comments (public repo) — sensitive values masked
- Atlantis with admin — per-stack roles + plan-only role is the hardening path
- 14-day log retention, CloudWatch instead of Prometheus/Grafana — cost on a $100 account

---

## If I had more time

- Per-stack Atlantis roles + permission boundaries; private infra repo
- SLOs with burn-rate alerts; AMP + PromQL (true p90 from API-server histograms)
- Multi-environment (dev/stage/prod) with ApplicationSets; restore drills
- Private EKS endpoint behind a VPN/SSM bastion; GuardDuty / Security Hub
