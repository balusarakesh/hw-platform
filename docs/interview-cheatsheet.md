# Interview cheat sheet

One line per feature, grouped by what the assignment asks about. Each line: **what** → *why*.

## Infrastructure as Code
- **5 Terraform stacks** (`bootstrap`, `persistent`, `cluster`, `alarms`, `ci`) → split by change rate and blast radius; 4 are Atlantis projects (serial plans).
- **Remote state**: S3 + SSE-KMS + versioning + public-access block + native S3 lockfile → no DynamoDB.
- **Reusable modules** (`network`, `aurora-serverless`, `ecr-repository`) wrapping pinned `terraform-aws-modules`.
- **Exact pins**: Terraform ≥ 1.17, providers `= x.y.z`, `.terraform.lock.hcl` for darwin + linux (amd64/arm64).
- **No hard-coded IDs/ARNs in Git**: Terraform writes them to SSM `/hw/gitops/*`; helmfile reads `ref+awsssm://`.
- **Sensitive inputs from SSM** (home IP, alert email) marked `sensitive` → never in plans, PR comments or Git.
- **Drift-resistant**: EKS addon versions pinned; explicit cluster/KMS admins (not "whoever runs Terraform").

## GitOps & CI/CD
- **Single public monorepo**, PR-only changes on `main` (ruleset: no force-push/delete, PR required, checks required).
- **Atlantis** (in-cluster, GitHub App) plans every Terraform PR, `atlantis apply` only when mergeable.
- **ArgoCD + helmfile** via a Config Management Plugin sidecar; one Application per app (`gitops/apps/<app>/`).
- **App-of-apps root** installed once by Terraform; ArgoCD then manages itself → bootstrap chicken-and-egg solved.
- **PR diff comments**: in-cluster runners run `argocd app diff` with a read-only account → ArgoCD stays private.
- **App pipeline**: PR → vet/test/lint/build/trivy (required checks); merge → arm64 build (GitHub runner) → in-cluster push runner → ECR → cosign sign (KMS) → bot opens image-bump PR with ArgoCD diff.
- **Two runner pools**: `hw-runners` (PR diffs, no AWS, no K8s token) and `hw-runners-push` (main only, ECR push + kms:Sign).
- **Images pinned by `tag@sha256`** everywhere (app, ArgoCD, controllers, sidecars).

## Security (baseline is pass/fail)
- **IAM**: one Pod Identity role per service account, least privilege (e.g. app = `rds-db:connect` as one DB user).
- **No static credentials** in cluster/CI; IRSA + GitHub OIDC blocked by account SCP → Pod Identity + in-cluster push.
- **Network**: nodes/pods private, Aurora in isolated subnets (no internet route), only ALB + NAT public.
- **Security groups**: RDS 5432 only from the app pods' SG; ALB → pods only via the LB controller backend SG.
- **Security groups for pods** (ENI trunking on m7g) + **NetworkPolicies** default-deny per namespace.
- **EKS API**: private endpoint + public endpoint restricted to the operator IP; API auth mode (access entries).
- **Encryption at rest**: KMS for Aurora, master secret, ECR, CloudWatch Logs, SNS, K8s Secrets (envelope), state; EBS encrypted.
- **Encryption in transit**: ALB TLS 1.3 policy, HSTS, HTTP→HTTPS redirect; app→Aurora `verify-full`, `rds.force_ssl=1`.
- **Secrets**: RDS-managed master password; app uses 15-min IAM tokens; ESO syncs GitHub/ArgoCD tokens from Secrets Manager.
- **Workloads**: non-root, read-only rootfs, no privilege escalation, caps dropped, seccomp, limits; PSA `restricted` enforced.
- **Supply chain**: ECR scan-on-push, immutable tags, trivy in CI, **cosign signatures (KMS key) enforced by Kyverno** in `hello-world` — unsigned image rejected, signed admitted (tested).
- **Edge**: AWS WAF — 10 RPS/IP → 429, AWS Common + Known Bad Inputs rules, Atlantis host GitHub-IPs-only.
- **IMDSv2 required, hop limit 1** → pods can't steal the node role.

## Observability (valued most)
- **Logs**: Fluent Bit → CloudWatch (KMS, 14-day retention); JSON access log per request with trace ID.
- **Metrics**: Container Insights (enhanced) + Prometheus scrape (app RED metrics, conntrack, HPA) + ENA ethtool.
- **Tracing**: OpenTelemetry SDK → CloudWatch agent → X-Ray; HTTP + DB spans, trace map, latency by route.
- **Alarms (→ SNS email)**: RPS > 10/s, p95 latency, 5xx, unhealthy targets, pods crashloop/pending/unavailable,
  HPA at max, node NotReady / at max / status check, ENA allowances, conntrack, control-plane P99/5xx/429, Aurora ACU, WAF 429s.
- **Per-node alarms** via Metrics Insights `GROUP BY` (multi-time-series) → follow nodes as they come and go.
- **Dashboard** `hw-overview`: alarms, app, pods/HPA, nodes/network, control plane, Aurora, WAF.
- **Health checks**: `/healthz` (liveness, no deps), `/readyz` (readiness, flips on shutdown), ALB health checks.

## Reliability & scaling
- **HPA** 2–6 replicas (CPU 70 %, memory 80 %) + **Cluster Autoscaler** on the managed node group (max 4).
- **VPA** (in-place pod resize, EKS 1.36) for ArgoCD components: resizes running pods without restarts; Git/Deployment unchanged → no ArgoCD drift; falls back to eviction only if in-place isn't possible.
- **2 AZs**, NAT per AZ, topology spread, PDB, rolling updates with `maxUnavailable: 0`.
- **Zero-downtime pod removal**: ALB pod readiness gates + preStop sleep + 30 s deregistration delay → 0 errors deleting pods at ~9 RPS (measured).
- **Graceful shutdown**: readiness off → wait → drain connections.
- **Node auto repair** (EKS node monitoring agent).
- **Aurora Serverless v2** 0.5–2 ACU (always on, no cold start), backups 7 days, deletion protection, Performance Insights.
- **m7g.medium nodes** (ENI trunking needed for pod SGs; t4g can't), migrated blue/green.

## Cost
- **$100/month budget** with alerts at 50/75/90 % + forecast.
- **`power.py down/up`**: nodes → 0 and Aurora stopped (control plane, NAT, ALB stay) → minutes to bring back.
- Graviton (arm64) nodes; single small node group; CloudWatch metric allowlists to cap custom-metric cost.

## Constraints I designed around (good talking points)
- **SCP region lock** → `us-east-2`. **SCP denies IAM OIDC** → Pod Identity, no GitHub OIDC.
- **SCP denies `ec2:CreateFleet`** → Cluster Autoscaler instead of Karpenter (EKS 1.36 to match CA).
- **Route 53 Domains unavailable** → domain at Dynadot, delegated to a Terraform-managed zone.
- **WAF can't front an NLB** → kept the ALB so rate limiting can return HTTP 429.

## Things that broke and how I found/fixed them (shows SRE judgement)
- ENA metrics silently dropped (Prometheus "untyped") → CloudWatch agent ethtool plugin.
- GitHub webhooks 403 by WAF body-size rule → scoped the rule set away from the Atlantis host.
- Atlantis plan would have replaced the operator's EKS admin access ("creator = whoever runs Terraform") → explicit admins.
- Power-down took 44 min (PDBs + serial Aurora stop) → drain bypassing PDBs + parallel stop.
- ArgoCD helmfile sidecar OOMKilled during a mass render → limits doubled.
- NAT-per-AZ change cut Atlantis' own egress mid-apply → state repaired (untaint/import); lesson: don't let Atlantis apply its own network path.
- Pod security groups: DNS to CoreDNS blocked (node SG accepted DNS only from itself) → bootstrap job failed, new DB connections hung → return rules added.
- Tracing turned on → pods crash-looped (OpenTelemetry "conflicting Schema URL") → fixed + regression test reproducing the exact error; old pods kept serving (maxUnavailable 0).
- Kyverno ServerSideDiff OOMKilled argocd-server (even at 1Gi) → client-side diff + targeted ignoreDifferences.
- Atlantis lock contention: a gitops PR touching ArgoCD values locked the `cluster` project → apply/merge order.
- LB controller webhook CA regenerated on every render (Helm genCA) → `ignoreDifferences` + `RespectIgnoreDifferences`.
- PR diff comment reported every app as "new" when the real error was permission denied → errors now shown as errors.
