# Interview walkthrough (demo script)

Order to show things live. Commands assume `aws`, `kubectl` (via `make kubeconfig`), `gh`, `hey`.

## 0. Before the call
```bash
scripts/.venv/bin/python scripts/power.py up --yes      # ~10 min; alarms back on, app check
scripts/.venv/bin/python scripts/power.py status
curl -s https://app.app-test-hw.click/readyz
```

## 1. The app (2 min)
- Open https://app.app-test-hw.click → click the button → rows from Aurora (first call after idle shows DB latency).
- `kubectl -n hello-world logs -l app.kubernetes.io/name=hello-world --tail=5` → JSON access logs with trace IDs.

## 2. Architecture (3 min)
- `docs/architecture.md` diagrams; `docs/presentation.md` slides 2–4.
- AWS console: VPC subnets/route tables (DB subnets have no 0.0.0.0/0), ALB + WAF, Aurora (not public).

## 3. Security (5 min)
- `kubectl get ns --show-labels` → PSA restricted; `kubectl get networkpolicy -A`; `kubectl get securitygrouppolicy -A`.
- IAM: Pod Identity associations `aws eks list-pod-identity-associations --cluster-name hw`.
- WAF: `hey -z 70s -q 20 -c 1 https://app.app-test-hw.click/` → 429s; Log4Shell header → 403.
- Signed images: try to run an unsigned image in `hello-world` → admission denied.
- Exposure / blast radius table (presentation slide 5).

## 4. Observability (5 min)
- CloudWatch dashboard `hw-overview`; alarm list (all OK); alarm history shows each was triggered once.
- X-Ray / Application Signals: trace map, a request trace with the DB span.
- Logs Insights: `fields @timestamp, log | filter log like /"msg":"request"/ | sort @timestamp desc`.

## 5. GitOps live change (5 min) — "make a live change"
1. Edit `gitops/apps/hello-world/values.yaml` (e.g. HPA `maxReplicas`) → PR → ArgoCD diff comment → merge → sync.
2. Edit an alarm threshold in `terraform/alarms/variables.tf` → PR → Atlantis plan comment → `atlantis apply` → merge.
3. Edit app UI text → PR → checks → merge → bump PR appears → merge → new signed image rolls out.

## 6. Resilience demos (optional)
- Delete a pod during `hey` → no 5xx (readiness gates + preStop).
- `power.py down` / `up` timings.

## 7. Wrap-up
- `docs/GAPS.md`: trade-offs and what's next (Atlantis privilege, SLOs, multi-env, private endpoint).
