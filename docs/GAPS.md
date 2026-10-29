# Known gaps & trade-offs

Each item: what it is → **TODO:** the planned fix / next step. Grouped by topic; account constraints first because they explain several choices.

## Account guardrails (SCPs on this AWS account, $100/month hard limit)
| Guardrail | Blocked | Used instead |
|---|---|---|
| Only `us-east-2` | other regions | `us-east-2` |
| `iam:*OpenIDConnectProvider` denied | IRSA, GitHub Actions OIDC | EKS Pod Identity; image push from an in-cluster runner |
| `ec2:CreateFleet` denied | Karpenter, EKS Auto Mode | Cluster Autoscaler (EKS 1.36 to match CA's minor) |
| Route 53 Domains registration fails | registering in AWS | Dynadot domain delegated to a Terraform-managed zone |

- GitHub-hosted runners have **no AWS identity** → anything needing AWS runs in-cluster. **TODO:** allow the GitHub OIDC provider.
- **EKS 1.36, not 1.37** (CA has no 1.37 release yet). **TODO:** bump EKS + CA together, or Karpenter.

## Repository & GitOps
- **Single public monorepo** (assignment). **TODO:** split app / infra / modules / gitops repos; version modules by git tag.
- **Plans and diffs are public PR comments.** Sensitive vars are masked; names/ARNs visible. **TODO:** private infra repo.
- **Chicken-and-egg PRs**: the PRs that installed Atlantis/runners and unblocked their webhooks were applied from the laptop.

## Security
- **GitHub App private key** is a long-lived (GitHub) credential in Secrets Manager. **TODO:** scheduled rotation + age alert.
- **EKS public endpoint** on, restricted to one IP. **TODO:** private-only + VPN / SSM bastion.
- **WAF**: rate limit is per IP and approximate (a few seconds of overshoot; clients behind one NAT share a budget);
- **AWS-managed addons run privileged/as root** (VPC CNI, kube-proxy, Pod Identity agent, node monitoring agent, CloudWatch agent, Fluent Bit) — **expected**, they program host networking or read host data. Accepted exception.
- **node-exporter** uses host namespaces (non-root, no caps); its namespace is the only PSA `privileged` one.
- **HTTPS egress is open to `0.0.0.0/0`** for controllers/app (AWS APIs, GitHub, ECR), and ArgoCD's egress isn't restricted. **TODO:** VPC endpoints (STS, Secrets Manager, ECR, X-Ray, logs) + an FQDN-aware egress proxy.
- **The image running when signature enforcement was turned on was signed once by hand** (bootstrap); every later image is signed by CI.
- **NetworkPolicies don't apply to host-network pods** (node-exporter, CloudWatch agent); they're governed by the node SG.

## Reliability
- **Single Aurora writer**, no reader: failover = new instance, minutes. **TODO:** reader in the second AZ.
- **Restores never tested.** **TODO:** periodic restore drill.
- **No SLOs / error budgets**; alarms are thresholds. **TODO:** availability + latency SLOs with burn-rate alerts.
- **No multi-environment** (dev/stage/prod). **TODO:** per-env stacks + ArgoCD ApplicationSets.
- **VPA recommendations follow recent load**: after busy periods it recommends high CPU for ArgoCD, which on 1-vCPU nodes can defer in-place resizes or add nodes. **TODO:** VPA manages memory only (`controlledResources: [memory]`, `RequestsOnly`).
- **Atlantis applying changes to its own network path** (e.g. NAT/route changes) can lose its state upload mid-apply. **TODO:** apply such changes from outside the cluster, or add S3/STS VPC endpoints.


## Observability
- **No Prometheus/Grafana**: a collector (CloudWatch agent) is needed either way; the gap is the *store/query layer* — CloudWatch instead of PromQL + Grafana. **TODO:** also remote-write to AMP, Grafana dashboards.
- **EC2 conntrack allowance** isn't exposed by `DescribeInstanceTypes`, so that threshold is still a variable (bandwidth baseline is derived).
- **CloudWatch custom metric cost** grows with dimensions → allowlists keep it small.
- **HPA `ScalingLimited` not alarmed** (also true at minReplicas); `hw-hpa-at-max` covers the real case.
