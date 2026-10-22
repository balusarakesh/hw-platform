# hw-platform — Known Gaps & Trade-offs

Each gap lists what was chosen, why, and what the fix would be.

## Account guardrails (SCPs on the AWS account)
The account is a project account with a **$100/month hard spend limit**, inside an AWS Organization whose
service control policies cap what even the account's admin can do. Each restriction, and what was built instead:

| Guardrail | Blocked | Used instead | In an unrestricted account |
|---|---|---|---|
| Only `us-east-2` allowed | Planned `us-west-2` | `us-east-2` | Any region |
| All `iam:*OpenIDConnectProvider` denied | **IRSA** (needs the cluster's OIDC issuer registered in IAM) | **EKS Pod Identity**: roles trust `pods.eks.amazonaws.com`; pairing via `aws_eks_pod_identity_association` | Either works; Pod Identity is AWS's current recommendation anyway |
| (same) | **GitHub Actions OIDC → AWS role** for pushing images to ECR | Phase 1: push from the laptop (`make image`). Phase 3: build on a GitHub-hosted runner, push from an in-cluster runner with a Pod Identity role scoped to the one ECR repo | GitHub OIDC provider + role trusted only for `repo:balusarakesh/hw-platform:ref:refs/heads/main` (no runner in the cluster needed) |
| `ec2:CreateFleet` denied | **Karpenter** (and EKS Auto Mode) launch nodes with CreateFleet | **Cluster Autoscaler** scaling the managed node group's ASG | Karpenter: faster, bin-packing, mixed instance types and Spot |
| Route 53 Domains registration fails (likely the account can't pay for domains) | Registering the domain in AWS | External registrar, NS delegated to a Terraform-managed Route 53 zone | Route 53 Domains |
| $100/month spend limit | Running everything 24/7 (~$135/month idle) | Power-off script, budget alerts at $50/$75/$90 | Normal budget alerts |

- **GitHub Actions has no AWS identity.** Because of the OIDC guardrail, nothing running on GitHub's
  infrastructure can authenticate to AWS without static keys, which the baseline forbids. Anything that needs
  AWS (ECR push) has to run in-cluster with Pod Identity, which widens what in-cluster runners can do.
  *Fix:* allow the GitHub OIDC provider; then CI pushes directly and in-cluster runners stay read-only.
- **EKS is on 1.36, not the newest 1.37.** Cluster Autoscaler releases track Kubernetes minors and the
  newest CA is v1.36.x. *Fix:* bump EKS and CA together when CA 1.37 ships (or Karpenter, which doesn't have this coupling).

## Repository & GitOps
- **Single monorepo** instead of separate `hw-app`, `hw-terraform`, `hw-terraform-modules` and `hw-gitops` repos.
  - *Why:* the PDF asks for one public repo, and one repo is quicker to build and review.
  - *Fix:* split the repos. Then:
    - modules are versioned with git tags (`source = "git::...//vpc?ref=v1.2.0"`), so stacks upgrade independently instead of all moving with every local edit;
    - each repo gets its own CODEOWNERS and access, so app devs can't touch infra;
    - CI triggers and release cadences are independent;
    - ArgoCD and Atlantis each watch only their own repo.
- **Atlantis plan output is public.** Plans post resource names, ARNs and account IDs on PRs in a public repo. Sensitive variables (home IP, alert email) are masked, but the rest of the plan isn't.
  - *Fix:* keep the infra repo private (this would need a separate repo, since the PDF requires the submission to be public), or use Atlantis `--hide-prev-plan-comments` and redact plan output.
- **`argocd app diff` comments are public**, for the same reason. Secret values are masked by ArgoCD, but manifests are visible.
- **Atlantis applies on `mergeable` with no required approval.** It's a solo repo, and GitHub doesn't allow approving your own PR.
  - *Fix:* in a team setup, require `approved` + CODEOWNERS on `terraform/**`.
- **Atlantis role is highly privileged** (it can change IAM, EKS, RDS). A compromised Atlantis pod or a malicious plan means account-level impact.
  - *Fix:* split roles per stack, plan-only role on PRs, permission boundaries, and run Atlantis outside the cluster it manages.
- **Atlantis runs in the cluster it manages** (chicken-and-egg). Bootstrap and disaster recovery are done with a local `terraform apply`.
- **ArgoCD bootstrap chicken-and-egg.** Terraform installs ArgoCD and the root app once (helm_release). ArgoCD then manages itself and everything else from `gitops/`.
- **Self-hosted runners on a public repo.** They are limited to same-repo PRs, fork workflows need approval, and the runner has read-only RBAC. A malicious collaborator could still run code in-cluster.
- **Image bumps need a human merge.** CI opens a PR to `gitops/`, so deploys aren't fully continuous.
  - *Why:* this is deliberate, so every prod change gets an ArgoCD diff and a review.

## Manual steps / credentials outside Terraform
- **Creating the GitHub App is manual.** Neither the GitHub API nor the `integrations/github` Terraform provider can create an App or generate its private key. The provider only has `github_app_installation_repository(ies)` to attach repos to an existing installation, which *is* managed in Terraform.
  - *Fix:* use the GitHub App manifest flow to make it one click; there is no full automation.
- **The GitHub App private key is a long-lived credential.** It isn't an AWS credential. It's stored in Secrets Manager and synced via ESO, and rotation is manual.
  - *Fix:* scheduled rotation plus alerting on key age.
- **Domain registration is outside Terraform and outside AWS.** Route 53 Domains rejected the registration on this
  account (instant failure, "contact Support"), so the domain is registered at an external registrar and its NS records
  point at a Route 53 zone that the bootstrap stack creates. Delegation is a manual step at the registrar.
  *Fix:* register in Route 53 Domains (or manage the registrar via its Terraform provider) so delegation is code too.
- **The SNS email subscription** must be confirmed by hand.
- **`/hw/admin_cidrs` (home IP)** is set by hand and must be updated when the home IP changes.

## Security
- **The EKS public endpoint is enabled,** restricted to my home IP.
  - *Fix:* private-only endpoint plus a VPN, SSM bastion or Client VPN.
- **The Atlantis webhook is public,** restricted to GitHub hook CIDRs and protected by a webhook secret.
- **No WAF on the ALB.** *Fix:* AWS WAF with managed rule groups and rate-based rules.
- **No image signing or admission policy.** *Fix:* cosign signing in CI and Kyverno/Gatekeeper to verify signatures and enforce the pod security baseline.
- **No GuardDuty, Security Hub or CloudTrail lake setup.** These are account-level and out of scope.
- **Pod-to-RDS access is controlled by the node SG, not security groups for pods.** Any pod on a node can reach port 5432 at the network level. IAM auth still limits *who* can log in, and NetworkPolicies limit which pods can connect.
  - *Fix:* SecurityGroupPolicy (security groups for pods).

## Reliability
- **Single NAT gateway.** Losing that AZ breaks egress for both AZs. *Fix:* one NAT per AZ.
- **Single Aurora writer, no reader.** Failover means recreating the instance, which takes minutes. *Fix:* add a reader in the second AZ.
- **Aurora `min_capacity = 0` (auto-pause).** The first request after idle waits about 15 s while the DB resumes. `/readyz` deliberately doesn't fail on a paused DB.
- **2 small nodes, one instance type.** Limited headroom; Cluster Autoscaler can add up to 3 nodes of the same type, but a node failure still squeezes the addons until a replacement joins (minutes).
- **Backups are configured but restores have never been tested.** *Fix:* a periodic restore drill.
- **No SLOs or error budgets.** Alarms are threshold-based. *Fix:* define availability and latency SLOs with burn-rate alerts.
- **No multi-environment setup** (dev/stage/prod). *Fix:* workspaces or per-env stacks, plus ArgoCD ApplicationSets.

## Cost / power-off
- **"Off" only terminates nodes and stops Aurora.** The EKS control plane, NAT, ALB, public IPs, KMS, Secrets Manager and Route 53 keep running, roughly $4–5/day.
  - The PDF says *"tear down the cluster when not actively working"*. This repo reads that as tearing down compute, and keeps the control plane so bring-up takes minutes instead of about 20.
  - *Fix:* if cost matters more, destroy the cluster stack instead.
- **Aurora auto-starts after 7 days stopped** (AWS limit). `power.py status` warns about this, but nothing re-stops it automatically.
  - *Fix:* an EventBridge rule that re-stops it.
- **`power.py` scales the node group outside Terraform.** The EKS module ignores `desired_size` changes, so there's no drift. `min_size` is 0 in Terraform for the same reason.
- **Alarms depend on the controller-created ALB.** The ALB is long-lived, but if the Ingress or IngressGroup is ever recreated, the `alarms` stack must be re-applied.
  - *Fix:* a Terraform-owned ALB + TargetGroupBinding.

## Observability
- **No Prometheus/Grafana stack.** Metrics go to CloudWatch via the CloudWatch agent. *Fix:* Amazon Managed Prometheus + Managed Grafana.
- **API server latency alarms on P99, not p90.**
  - *Why:* EKS vends only P99 to CloudWatch, and CloudWatch can't run `histogram_quantile` on scraped histograms. P99 > 3 s catches every case p90 > 3 s would, but may be noisier.
  - *Fix:* AMP + a PromQL alert on p90.
- **Node alarms are cluster-wide ("worst node"), not per node.** Nodes come and go, so per-instance alarms would break. The alarm says *a* node is affected, and the dashboard shows which one.
  - *Fix:* CloudWatch multi-time-series (Metrics Insights `GROUP BY`) alarms, or Prometheus alerting with per-node labels.
- **The EC2 status-check alarm aggregates over the node group's ASG.** It says *a* node failed; node auto repair
  replaces it. *Fix:* per-instance alarms created by an EventBridge rule on instance launch.
- **AWS-managed addon pods may run as root.** Fluent Bit and possibly the CloudWatch agent come from the CloudWatch observability addon. These are the only exceptions to the non-root baseline, listed per container in the README.
  - *Fix:* self-manage them with non-root settings where the tool allows it.
- **node-exporter uses host namespaces** (hostNetwork, hostPID, read-only `/proc` and `/sys`), while running as non-root and unprivileged with no capabilities. It can *see* node-level information.
  - *Fix:* Pod Security Admission `restricted` on all app namespaces, with the monitoring namespace as the only one at `privileged`/`baseline`.
- **CloudWatch custom metrics cost.** It grows with metric × dimension combinations, so `metric_declaration` allowlists keep it small. Adding per-pod or per-route dimensions would multiply the cost.
- **Instance limits are hand-maintained variables.** The network baseline and conntrack allowance thresholds come from the instance type. If the instance type changes, the variables must change too.
  - *Fix:* derive them from `ec2:DescribeInstanceTypes` in Terraform.
- **Alarms are tested by hand.** Some are tested with `set-alarm-state` rather than real failures (EC2 status checks, control plane). There's no automated alert testing.
- **No distributed tracing.** *Fix:* OpenTelemetry SDK + ADOT → X-Ray.
- **Alarms go to email only, with no on-call routing.** *Fix:* SNS → PagerDuty/Opsgenie/Slack.
