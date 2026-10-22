# Thin wrappers so the deploy order is written down once. Run `make help`.
SHELL        := /bin/bash
AWS_PROFILE  ?= default
TF           := terraform
STACK        ?= persistent
TF_DIR        = terraform/$(STACK)

.PHONY: help
help: ## List targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  %-22s %s\n",$$1,$$2}'

# --- one-time bootstrap (state bucket, GitHub repo, OIDC, budget) -------------------------------

.PHONY: bootstrap
bootstrap: ## First apply of terraform/bootstrap with local state, then migrate state into S3
	@test -n "$$GITHUB_TOKEN" || { echo 'export GITHUB_TOKEN=$$(gh auth token) first'; exit 1; }
	printf 'terraform {\n  backend "local" {}\n}\n' > terraform/bootstrap/backend_override.tf
	$(TF) -chdir=terraform/bootstrap init -reconfigure
	$(TF) -chdir=terraform/bootstrap apply
	$(TF) -chdir=terraform/bootstrap output -raw backend_hcl > terraform/backend.hcl
	rm terraform/bootstrap/backend_override.tf
	$(TF) -chdir=terraform/bootstrap init -migrate-state -force-copy -backend-config=../backend.hcl
	rm -f terraform/bootstrap/terraform.tfstate terraform/bootstrap/terraform.tfstate.backup

# --- regular stacks: make plan STACK=persistent | cluster ------------------------------------------

.PHONY: init plan apply
init: ## terraform init for $(STACK) against the S3 backend
	$(TF) -chdir=$(TF_DIR) init -backend-config=../backend.hcl

plan: init ## terraform plan for $(STACK)
	$(TF) -chdir=$(TF_DIR) plan -out=tfplan

apply: ## terraform apply the saved plan for $(STACK)
	$(TF) -chdir=$(TF_DIR) apply tfplan

.PHONY: kubeconfig
kubeconfig: ## Point kubectl at the cluster
	$$($(TF) -chdir=terraform/cluster output -raw kubeconfig_command)

# --- app image ------------------------------------------------------------------------------------

.PHONY: test image
test: ## Go vet + tests
	cd app && go vet ./... && go test ./...

image: ## Build arm64 image locally (Colima), push to ECR, write tag+digest into gitops values
	scripts/push-image.sh

# --- checks ---------------------------------------------------------------------------------------

.PHONY: lint
lint: ## fmt/validate/tflint/checkov/helm lint
	$(TF) fmt -check -recursive terraform
	for d in terraform/bootstrap terraform/persistent terraform/cluster; do \
	  $(TF) -chdir=$$d init -backend=false -input=false >/dev/null && $(TF) -chdir=$$d validate && (cd $$d && tflint); done
	checkov -d . --config-file .checkov.yaml --compact --quiet
	helm lint gitops/charts/hello-world --set region=x,image.repository=x,image.tag=x,image.digest=x,serviceAccount.roleArn=x,dbBootstrap.roleArn=x,ingress.host=x,ingress.certificateArn=x
