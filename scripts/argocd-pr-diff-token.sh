#!/usr/bin/env bash
# One-time (or rotation): mint an API token for ArgoCD's read-only `pr-diff` account and store it in
# Secrets Manager (hw/argocd/pr-diff-token). External Secrets copies it to the in-cluster runners,
# which use it for `argocd app diff` in .github/workflows/gitops-diff.yml.
#
# Run from a laptop with kubectl pointed at the cluster (make kubeconfig), after ArgoCD has synced the
# pr-diff account from gitops/apps/argocd/values.yaml. The token is never printed.
set -euo pipefail

profile="${AWS_PROFILE:-default}"
region="${AWS_REGION:-us-east-2}"
secret_id="hw/argocd/pr-diff-token"
port=18443

kubectl -n argocd get configmap argocd-cm -o jsonpath='{.data.accounts\.pr-diff}' | grep -q apiKey \
  || { echo "ArgoCD has no pr-diff account yet; sync the argocd app first" >&2; exit 1; }

kubectl -n argocd port-forward svc/argocd-server "${port}:443" >/dev/null 2>&1 &
pf_pid=$!
trap 'kill "$pf_pid" 2>/dev/null || true' EXIT
for _ in $(seq 1 20); do
  nc -z localhost "$port" 2>/dev/null && break
  sleep 0.5
done

# Admin session only for minting the token; the CLI context lives in a throwaway config dir.
export ARGOCD_CONFIG_DIR
ARGOCD_CONFIG_DIR="$(mktemp -d)"
trap 'kill "$pf_pid" 2>/dev/null || true; rm -rf "$ARGOCD_CONFIG_DIR"' EXIT

admin_password="$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
# --insecure: the port-forwarded server presents ArgoCD's self-signed certificate.
argocd login "localhost:${port}" --username admin --password "$admin_password" --insecure --grpc-web >/dev/null
unset admin_password

token="$(argocd account generate-token --account pr-diff --server "localhost:${port}" --insecure --grpc-web)"

if aws secretsmanager describe-secret --secret-id "$secret_id" --region "$region" --profile "$profile" >/dev/null 2>&1; then
  aws secretsmanager put-secret-value --secret-id "$secret_id" --secret-string "$token" \
    --region "$region" --profile "$profile" >/dev/null
else
  aws secretsmanager create-secret --name "$secret_id" --kms-key-id alias/hw-data \
    --description "ArgoCD read-only pr-diff account token (hw-platform PR diffs)" \
    --secret-string "$token" --region "$region" --profile "$profile" >/dev/null
fi
unset token

echo "stored token in Secrets Manager: ${secret_id}"
echo "force a refresh: kubectl -n arc-runners annotate externalsecret argocd-pr-diff-token force-sync=\$(date +%s) --overwrite"
