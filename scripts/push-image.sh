#!/usr/bin/env bash
# Build the app for linux/arm64, push it to ECR tagged with the current commit, and pin
# tag + digest in gitops/apps/hello-world/values.yaml. Used for the very first image
# (before CI exists) and as a manual fallback; CI does the same thing on merge to main.
set -euo pipefail

cd "$(dirname "$0")/.."
profile="${AWS_PROFILE:-default}"
region="$(terraform -chdir=terraform/persistent output -raw region)"
repo="$(terraform -chdir=terraform/persistent output -raw ecr_repository_url)"
registry="${repo%%/*}"

if [[ -n "$(git status --porcelain -- app)" ]]; then
  echo "app/ has uncommitted changes; commit first so the tag matches the code" >&2
  exit 1
fi
tag="$(git rev-parse HEAD)"

aws ecr get-login-password --region "$region" --profile "$profile" \
  | docker login --username AWS --password-stdin "$registry"

docker buildx build --platform linux/arm64 --provenance=false \
  -t "$repo:$tag" --push app

digest="$(crane digest "$repo:$tag")"

values=gitops/apps/hello-world/values.yaml
# Only the two indented image lines change; everything else in the file is left alone.
sed -i.bak -E \
  -e "s|^(  tag: ).*|\\1\"$tag\"|" \
  -e "s|^(  digest: ).*|\\1\"$digest\"|" \
  "$values" && rm -f "$values.bak"

echo "pushed $repo:$tag@$digest"
