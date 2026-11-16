# Local entrypoint. `make all` deploys the whole project on a fresh computer.
# Must run on GNU Make 3.81 (the macOS default): no .ONESHELL, .SHELLFLAGS or `!=`.

SHELL := /bin/bash

# GHCR needs a lowercase owner. CI overrides IMAGE and passes the full commit SHA.
IMAGE ?= ghcr.io/dorzvulun/whatsmyip
GIT_SHA ?= $(shell git rev-parse --short HEAD)
PYTHON_VERSION := 3.13

.DEFAULT_GOAL := all
.PHONY: all
all: venv lint test build scan cluster-create deploy smoke

# --- App: venv, lint, unit tests, local run ---

VENV := .venv

.PHONY: venv lint test run

venv: $(VENV)/.stamp

$(VENV)/.stamp: requirements-dev.txt
	uv venv --clear --python $(PYTHON_VERSION) $(VENV)
	uv pip install --python $(VENV) --require-hashes -r requirements-dev.txt
	touch $@

lint: venv
	$(VENV)/bin/ruff check .
	$(VENV)/bin/ruff format --check .

test: venv
	$(VENV)/bin/pytest

run: venv
	$(VENV)/bin/gunicorn --bind 0.0.0.0:8080 --chdir app whatsmyip:app

# --- Container: build, vulnerability scan, SBOM ---

.PHONY: build scan scan-sarif sbom

build:
	docker build -t $(IMAGE):$(GIT_SHA) .

# Gate: fail on fixable HIGH/CRITICAL.
scan:
	trivy image --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 $(IMAGE):$(GIT_SHA)

scan-sarif:
	trivy image --severity HIGH,CRITICAL --ignore-unfixed --format sarif --output trivy.sarif $(IMAGE):$(GIT_SHA)

sbom:
	trivy image --format cyclonedx --output sbom.cdx.json $(IMAGE):$(GIT_SHA)

# --- Cluster and deploy: k3d cluster, helm lint, Terraform deploy, smoke test ---

CLUSTER ?= bigid
NAMESPACE ?= staging
IMAGE_SOURCE ?= local
SMOKE_URL ?= http://localhost:8080
# Dedicated kubeconfig for this cluster: k3d never touches the user's default kubeconfig.
KUBECONFIG_FILE ?= $(HOME)/.kube/big-id-k3d-config.yaml

.PHONY: cluster-create cluster-delete helm-lint deploy smoke trace-hops

cluster-create:
	k3d cluster get $(CLUSTER) >/dev/null 2>&1 || k3d cluster create --config k3d-config.yaml
	mkdir -p $(dir $(KUBECONFIG_FILE))
	k3d kubeconfig get $(CLUSTER) > $(KUBECONFIG_FILE)
	chmod 600 $(KUBECONFIG_FILE)

cluster-delete:
	k3d cluster delete $(CLUSTER)
	rm -f infra/terraform.tfstate infra/terraform.tfstate.backup $(KUBECONFIG_FILE)

helm-lint:
	helm lint --strict charts/whatsmyip --set image.tag=lint

deploy:
	if [ "$(IMAGE_SOURCE)" = local ]; then k3d image import $(IMAGE):$(GIT_SHA) -c $(CLUSTER); fi
	terraform -chdir=infra init -input=false
	terraform -chdir=infra apply -auto-approve -input=false \
		-var image_repository=$(IMAGE) -var image_tag=$(GIT_SHA) \
		-var namespace=$(NAMESPACE) -var kube_context=k3d-$(CLUSTER) -var kubeconfig=$(KUBECONFIG_FILE)

smoke:
	@for p in /health /ready; do \
		ok=; for i in $$(seq 30); do curl -fsS $(SMOKE_URL)$$p >/dev/null 2>&1 && ok=1 && break; sleep 1; done; \
		[ -n "$$ok" ] || { echo "smoke: $$p failed"; exit 1; }; \
	done
	@curl -fsS -H 'X-Forwarded-For: 203.0.113.7' $(SMOKE_URL)/ | grep -q 203.0.113.7 || { echo "smoke: / did not return forwarded IP"; exit 1; }
	@echo smoke ok

# Show the source address at every local network hop for one request (see README Limitations).
trace-hops:
	CLUSTER=$(CLUSTER) SMOKE_URL=$(SMOKE_URL) scripts/trace_hops.sh

# --- Secrets ---
# Push secrets to GitHub Actions. gh asks for the value in a hidden prompt; it never lands in a file.
# Optional: without ANTHROPIC_API_KEY the CI ai-diagnose job skips.
.PHONY: secrets
secrets:
	gh secret set ANTHROPIC_API_KEY
