#!/usr/bin/env bash
# Checks that the tools this course needs are installed and that the
# training cluster is reachable. Safe to run as often as you like - it only
# reads things, it never changes your machine or your cluster.
#
#   bash modules/00-setup/check-setup.sh
#
# Works with the bash 3.2 that ships with macOS, and inside WSL2.

ok()   { printf '  [ ok ] %s\n' "$*"; }
warn() { printf '  [warn] %s\n' "$*"; }
fail() { printf '  [FAIL] %s\n' "$*"; failures=$((failures + 1)); }
failures=0

echo "1. Container engine"
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  ok "docker $(docker version --format '{{.Server.Version}}' 2>/dev/null) is running"
elif command -v podman >/dev/null 2>&1 && podman info >/dev/null 2>&1; then
  ok "podman $(podman version --format '{{.Version}}' 2>/dev/null) is running"
  if [ "${KIND_EXPERIMENTAL_PROVIDER:-}" != "podman" ]; then
    warn "using podman: export KIND_EXPERIMENTAL_PROVIDER=podman before running kind"
  fi
else
  fail "neither docker nor podman is installed and running (is Docker Desktop started?)"
fi

echo "2. kubectl"
if command -v kubectl >/dev/null 2>&1; then
  # `kubectl version --client -o json` is stable across versions; pull out gitVersion.
  kv=$(kubectl version --client -o json 2>/dev/null | grep '"gitVersion"' | head -1 | sed 's/.*"\(v[^"]*\)".*/\1/')
  ok "kubectl ${kv:-unknown}"
else
  fail "kubectl not found on PATH"
fi

echo "3. kind"
if command -v kind >/dev/null 2>&1; then
  ok "$(kind version)"
else
  fail "kind not found on PATH"
fi

echo "4. Cluster"
if ! command -v kubectl >/dev/null 2>&1; then
  fail "skipped (no kubectl)"
elif ! kubectl cluster-info >/dev/null 2>&1; then
  fail "cannot reach a cluster with context '$(kubectl config current-context 2>/dev/null)'"
  echo "         create it with: kind create cluster --config cluster/kind-multi-node.yaml"
else
  ctx=$(kubectl config current-context)
  [ "$ctx" = "kind-kube-training" ] && ok "current context is $ctx" \
    || warn "current context is '$ctx' (expected kind-kube-training): kubectl config use-context kind-kube-training"
  sv=$(kubectl version -o json 2>/dev/null | grep '"gitVersion"' | tail -1 | sed 's/.*"\(v[^"]*\)".*/\1/')
  ok "server version ${sv:-unknown}"
  # kubectl supports +/- one minor version of the API server ("version skew policy").
  cm=$(echo "$kv" | cut -d. -f2); sm=$(echo "$sv" | cut -d. -f2)
  if [ -n "$cm" ] && [ -n "$sm" ]; then
    d=$((cm - sm)); [ $d -lt 0 ] && d=$((-d))
    [ $d -le 1 ] && ok "kubectl/server skew is $d minor version(s)" \
      || warn "kubectl $kv and server $sv are more than one minor version apart"
  fi
  total=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
  ready=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l | tr -d ' ')
  [ "$total" -gt 0 ] && [ "$total" = "$ready" ] && ok "$ready/$total nodes Ready" \
    || fail "$ready/$total nodes Ready (wait a minute after creating the cluster)"
  notrunning=$(kubectl get pods -n kube-system --no-headers 2>/dev/null | awk '$3!="Running"' | wc -l | tr -d ' ')
  [ "$notrunning" = "0" ] && ok "all kube-system pods Running" \
    || warn "$notrunning kube-system pod(s) not Running yet: kubectl get pods -n kube-system"
  sc=$(kubectl get storageclass -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{end}' 2>/dev/null)
  [ -n "$sc" ] && ok "default StorageClass: $sc" || warn "no default StorageClass (module 06 needs one)"
fi

echo
if [ $failures -eq 0 ]; then
  echo "All good - continue with the Lab in modules/00-setup/README.md"
else
  echo "$failures problem(s) found - see modules/00-setup/README.md, section 'Install the tools'"
  exit 1
fi
