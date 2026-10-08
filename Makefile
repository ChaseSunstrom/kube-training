# Convenience targets. Every target is a thin wrapper - read it to learn the
# underlying command.
CLUSTER_NAME ?= kube-training

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

.PHONY: cluster-up
cluster-up: ## Create the 3-node kind cluster (1 control-plane, 2 workers)
	kind create cluster --config cluster/kind-multi-node.yaml
	kubectl get nodes -L training/zone

.PHONY: cluster-up-single
cluster-up-single: ## Create a 1-node kind cluster (low-RAM machines)
	kind create cluster --config cluster/kind-single-node.yaml
	kubectl get nodes

.PHONY: cluster-down
cluster-down: ## Delete the kind cluster
	kind delete cluster --name $(CLUSTER_NAME)

.PHONY: validate
validate: ## Schema-check every manifest with kubeconform (no cluster needed)
	scripts/validate.sh

.PHONY: check-links
check-links: ## Check every relative link (and #anchor) in the Markdown files
	python3 scripts/check_links.py

.PHONY: test-scenario
test-scenario: ## Run the RWO ordered-pods scenario end-to-end on the current cluster
	scenarios/rwo-pvc-ordered-pods/test.sh

.PHONY: labs
labs: ## List lab namespaces that currently exist
	@kubectl get namespaces -o name | grep '^namespace/lab-' || echo "no lab namespaces"

.PHONY: clean-labs
clean-labs: ## Delete every lab-* namespace (resets all modules)
	@ns=$$(kubectl get namespaces -o name | grep '^namespace/lab-' || true); \
	if [ -n "$$ns" ]; then kubectl delete $$ns; else echo "nothing to delete"; fi
