# Known gaps & trade-offs

Each item: what it is → *fix / next step*. Grouped by topic; account constraints first because they explain several choices.

## Account guardrails (SCPs on this AWS account, $100/month hard limit)
| Guardrail | Blocked | Used instead |
|---|---|---|
| Only `us-east-2` | other regions | `us-east-2` |
| `iam:*OpenIDConnectProvider` denied | IRSA, GitHub Actions OIDC | EKS Pod Identity; image push from an in-cluster runner |
| `ec2:CreateFleet` denied | Karpenter, EKS Auto Mode | Cluster Autoscaler (EKS 1.36 to match CA's minor) |
| Route 53 Domains registration fails | registering in AWS | Dynadot domain delegated to a Terraform-managed zone |

- GitHub-hosted runners have **no AWS identity** → anything needing AWS runs in-cluster. *Fix:* allow the GitHub OIDC provider.
- **EKS 1.36, not 1.37** (CA has no 1.37 release yet). *Fix:* bump EKS + CA together, or Karpenter.

## Repository & GitOps
- **Single public monorepo** (assignment). *Fix:* split app / infra / modules / gitops repos; version modules by git tag.
- **Plans and diffs are public PR comments.** Sensitive vars are masked; names/ARNs visible. *Fix:* private infra repo.
- **No required approvals** (solo repo; GitHub forbids self-approval). *Fix:* CODEOWNERS + required reviews in a team.
- **Atlantis has AdministratorAccess** + EKS admin → biggest blast radius. *Fix:* per-stack roles, plan-only role on PRs, permission boundaries, Atlantis outside the cluster it manages.
- **Atlantis uses emptyDir** (no EBS CSI driver): locks/plans lost on restart. *Fix:* EBS CSI + PVC or Redis locks.
- **Webhook allowlist = GitHub `hooks` ranges** read at plan time; new GitHub ranges need a re-apply.
- **Chicken-and-egg PRs**: the PRs that installed Atlantis/runners and unblocked their webhooks were applied from the laptop.
- **ArgoCD diff**: doesn't cover an app's own `application.yaml`; uses `--insecure` to argocd-server (self-signed cert). *Fix:* diff the root app; cert-manager internal cert.
- **Non-expiring `pr-diff` ArgoCD token**, manual rotation. *Fix:* scheduled rotation / `--expires-in`.
- **Self-hosted runners on a public repo**: same-repo PRs only, no AWS role/K8s token for PR runners; push runner only for `main`.
- **Image bumps need a human merge** (deliberate: every deploy gets a diff + review).
- **Addon versions pinned** → bumps are deliberate; node AMI still follows latest (security patches show as node group updates).

## Security
- **Operator credential**: laptop `default` profile = `admin` IAM user with a long-lived key (pre-existing; nothing in cluster/CI uses static keys). *Fix:* `aws login` / Identity Center, delete the key.
- **GitHub App private key** is a long-lived (GitHub) credential in Secrets Manager. *Fix:* scheduled rotation + age alert.
- **EKS public endpoint** on, restricted to one IP. *Fix:* private-only + VPN / SSM bastion.
- **WAF**: rate limit is per IP and approximate (a few seconds of overshoot; clients behind one NAT share a budget); managed rules in block mode without a count-mode trial; Common rule set skipped for the Atlantis host (GitHub payloads exceed its 8 KB body rule — host is IP-allowlisted + HMAC). *Fix:* per-path/header keys, count-mode rollout.
- **AWS-managed addons run privileged/as root** (VPC CNI, kube-proxy, Pod Identity agent, node monitoring agent, CloudWatch agent, Fluent Bit) — **expected**, they program host networking or read host data. Accepted exception.
- **node-exporter** uses host namespaces (non-root, no caps); its namespace is the only PSA `privileged` one.
- **HTTPS egress is open to `0.0.0.0/0`** for controllers/app (AWS APIs, GitHub, ECR), and ArgoCD's egress isn't restricted. *Fix:* VPC endpoints (STS, Secrets Manager, ECR, X-Ray, logs) + an FQDN-aware egress proxy.
- **The image running when signature enforcement was turned on was signed once by hand** (bootstrap); every later image is signed by CI.
- **NetworkPolicies don't apply to host-network pods** (node-exporter, CloudWatch agent); they're governed by the node SG.
- **No GuardDuty / Security Hub / CloudTrail Lake** (account-level). *Fix:* enable in the org.

## Reliability
- **Single Aurora writer**, no reader: failover = new instance, minutes. *Fix:* reader in the second AZ.
- **Restores never tested.** *Fix:* periodic restore drill.
- **No SLOs / error budgets**; alarms are thresholds. *Fix:* availability + latency SLOs with burn-rate alerts.
- **No multi-environment** (dev/stage/prod). *Fix:* per-env stacks + ArgoCD ApplicationSets.
- **Small fleet**: m7g.medium (1 vCPU) nodes, CA up to 4; the platform requests ~2.2 vCPU, so steady state is 3 nodes. *Fix:* fewer, larger nodes or trim per-pod requests.
- **VPA recommendations follow recent load**: after busy periods it recommends high CPU for ArgoCD, which on 1-vCPU nodes can defer in-place resizes or add nodes. *Fix:* VPA manages memory only (`controlledResources: [memory]`, `RequestsOnly`).
- **Atlantis applying changes to its own network path** (e.g. NAT/route changes) can lose its state upload mid-apply. *Fix:* apply such changes from outside the cluster, or add S3/STS VPC endpoints.

## Cost / power-off
- **`down` stops nodes + Aurora only**; control plane, 2 NATs, ALB, WAF keep billing (~$6/day). *Fix:* destroy the cluster stack when idle.
- **Aurora 0.5 ACU minimum** (always available, no cold start) costs ~$1.45/day vs ~$0 at 0 ACU; **NAT per AZ** adds ~$1.20/day.
- **AWS restarts a stopped Aurora after 7 days**; `power.py status` warns, nothing re-stops it. *Fix:* EventBridge rule.
- `power.py` scales the node group outside Terraform (module ignores desired-size drift; saved size in SSM).
- `power.py` cost estimate is a static price table (no data transfer/LCU/storage).

## Observability
- **No Prometheus/Grafana**: a collector (CloudWatch agent) is needed either way; the gap is the *store/query layer* — CloudWatch instead of PromQL + Grafana. *Fix:* also remote-write to AMP, Grafana dashboards.
- **Control-plane latency alarms on P99, not p90**: EKS only vends P99, and CloudWatch can't compute quantiles from histogram buckets. *Fix:* scrape the API server's `apiserver_request_duration_seconds_bucket` into a Prometheus store and alert on `histogram_quantile(0.9, …)`.
- **ENA "exceeded" counters** are cumulative → alarmed as a cluster-wide per-minute DIFF; gauges (conntrack available) are per-node multi-time-series.
- **EC2 conntrack allowance** isn't exposed by `DescribeInstanceTypes`, so that threshold is still a variable (bandwidth baseline is derived).
- **One Prometheus scraper replica**: if it's down, Prometheus-based alarms go missing-data (OK). *Fix:* heartbeat alarm or 2 replicas.
- **CloudWatch custom metric cost** grows with dimensions → allowlists keep it small.
- **14-day log retention** everywhere (cost). *Fix:* longer retention / S3 export for audit.
- **HPA `ScalingLimited` not alarmed** (also true at minReplicas); `hw-hpa-at-max` covers the real case.
- **Email-only alerting**. *Fix:* SNS → PagerDuty / Slack.
- **Some alarms tested with `set-alarm-state`** (EC2 status check, control plane) because they can't be triggered safely.
