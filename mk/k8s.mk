CLUSTER ?= bigid
NAMESPACE ?= staging
IMAGE_SOURCE ?= local
SMOKE_URL ?= http://localhost:8080
# Project-local kubeconfig: k3d never touches the user's default kubeconfig.
KUBECONFIG_FILE ?= $(CURDIR)/.kubeconfig

.PHONY: cluster-create cluster-delete helm-lint deploy smoke

cluster-create:
	k3d cluster get $(CLUSTER) >/dev/null 2>&1 || k3d cluster create --config k3d-config.yaml
	k3d kubeconfig get $(CLUSTER) > $(KUBECONFIG_FILE)

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
