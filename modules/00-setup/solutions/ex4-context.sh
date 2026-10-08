#!/usr/bin/env bash
# Exercise 4 - a second context pointing at the same cluster (reference solution).
#   bash modules/00-setup/solutions/ex4-context.sh
set -euo pipefail

# Remember where we started, so we can switch back.
orig=$(kubectl config current-context)

# A context is just a name for (cluster, user, namespace). Reuse the
# cluster and user entries that kind created.
kubectl config set-context kt-setup \
  --cluster=kind-kube-training \
  --user=kind-kube-training \
  --namespace=lab-setup

kubectl config use-context kt-setup
kubectl config get-contexts
kubectl get pods          # no -n: uses the context's namespace, lab-setup

kubectl config use-context "$orig"
kubectl config delete-context kt-setup
