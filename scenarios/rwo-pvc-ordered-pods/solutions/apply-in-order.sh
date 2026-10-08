#!/usr/bin/env bash
# Exercise solution: ordering from OUTSIDE the cluster.
#
# Instead of init containers, the deploy script (or CI pipeline) enforces
# the order with `kubectl wait`. This is the simplest option when you control
# how things are deployed and don't want RBAC or extra containers in the pods.
# It is also what Helm hooks and Argo CD sync waves do for you.
#
# Downsides compared with the in-cluster patterns:
#   * the order only holds when people deploy through this script
#   * if pod B is recreated later (node drain, rollout restart) nothing
#     re-checks that pod A's work is still valid
#
# Reuses pattern 1's manifests. With this approach pod B's waiting init
# containers are no longer needed, but they don't hurt: they pass immediately
# because the Job is already complete when pod B is created.
set -euo pipefail
D="$(cd "$(dirname "${BASH_SOURCE[0]}")/../1-sequential-job-then-app" && pwd)"
NS=lab-rwo-sequential

kubectl apply -f "$D/00-namespace.yaml" -f "$D/01-pvc.yaml" -f "$D/02-rbac.yaml"

echo "step 1: run pod A (seed Job) and wait for it to complete"
kubectl apply -f "$D/03-job-seed.yaml"
if ! kubectl -n "$NS" wait --for=condition=complete job/seed --timeout=5m; then
  echo "seed Job did not complete - NOT starting pod B" >&2
  kubectl -n "$NS" logs job/seed --tail=20 >&2 || true
  exit 1
fi

echo "step 2: start pod B (web) and its Service"
kubectl apply -f "$D/04-deployment-web.yaml" -f "$D/05-service.yaml"
kubectl -n "$NS" rollout status deployment/web --timeout=5m
echo "done - try: kubectl -n $NS port-forward svc/web 8080:80"
