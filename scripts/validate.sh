#!/usr/bin/env bash
# Schema-validate every Kubernetes manifest in the repo with kubeconform.
# No cluster needed. Also renders Kustomize overlays and the Helm chart (when
# kubectl / helm are installed) and validates the output.
#
#   scripts/validate.sh
#
# kubeconform is downloaded into .bin/ on first use if it isn't on PATH.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
K8S_VERSION="${K8S_VERSION:-1.37.0}"
KUBECONFORM_VERSION="v0.6.7"
BIN="$ROOT/.bin"

kubeconform_bin() {
  if command -v kubeconform >/dev/null 2>&1; then command -v kubeconform; return; fi
  if [[ ! -x "$BIN/kubeconform" ]]; then
    local os arch
    os="$(uname -s | tr '[:upper:]' '[:lower:]')"
    arch="$(uname -m)"; case "$arch" in x86_64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; esac
    mkdir -p "$BIN"
    echo "downloading kubeconform $KUBECONFORM_VERSION ($os/$arch) into .bin/" >&2
    curl -fsSL "https://github.com/yannh/kubeconform/releases/download/${KUBECONFORM_VERSION}/kubeconform-${os}-${arch}.tar.gz" \
      | tar -xz -C "$BIN" kubeconform
  fi
  echo "$BIN/kubeconform"
}
KUBECONFORM="$(kubeconform_bin)"

# -strict: unknown fields are errors (catches typos like `contianers:`).
# CRDs (Gateway API etc.) are validated against the community CRDs catalog;
# anything without a published schema is reported as skipped, not failed.
KC_ARGS=(
  -strict -summary -output text
  -kubernetes-version "$K8S_VERSION"
  -schema-location default
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
  -ignore-missing-schemas
)

# Plain manifests: everything under modules/ and scenarios/ except files that
# are not standalone Kubernetes objects: Helm charts, values files, and
# anything inside a Kustomize tree (patches are partial objects - those trees
# are validated below through `kubectl kustomize`).
mapfile -t KUSTOMIZE_DIRS < <(find modules scenarios -name kustomization.yaml -exec dirname {} \; | sort)
in_kustomize_tree() {
  local f="$1" d
  for d in "${KUSTOMIZE_DIRS[@]}"; do
    # a kustomization's own dir and everything below it (e.g. patches/)
    [[ "$f" == "$d/"* ]] && return 0
  done
  return 1
}
FILES=()
while IFS= read -r f; do
  in_kustomize_tree "$f" || FILES+=("$f")
done < <(
  find modules scenarios -type f \( -name '*.yaml' -o -name '*.yml' \) \
    -not -path '*/chart/*' -not -path '*/charts/*' \
    -not -name 'Chart.yaml' -not -name 'values*.yaml' \
    -not -name '*.kind.yaml' -not -name 'kind-*.yaml' \
    | sort
)

status=0
echo "==> ${#FILES[@]} manifest files"
"$KUBECONFORM" "${KC_ARGS[@]}" "${FILES[@]}" || status=1

# Kustomize overlays/bases: every directory with a kustomization.yaml.
if command -v kubectl >/dev/null 2>&1; then
  while IFS= read -r k; do
    dir="$(dirname "$k")"
    echo "==> kustomize build $dir"
    if ! kubectl kustomize "$dir" | "$KUBECONFORM" "${KC_ARGS[@]}" -; then status=1; fi
  done < <(find modules scenarios -name kustomization.yaml -not -path '*/components/*' | sort)
else
  echo "(kubectl not found - skipping kustomize builds)"
fi

# Helm charts: every directory with a Chart.yaml.
if command -v helm >/dev/null 2>&1; then
  while IFS= read -r c; do
    dir="$(dirname "$c")"
    echo "==> helm lint + template $dir"
    helm lint "$dir" >/dev/null || { echo "helm lint failed for $dir"; status=1; }
    if ! helm template validate "$dir" | "$KUBECONFORM" "${KC_ARGS[@]}" -; then status=1; fi
  done < <(find modules scenarios -name Chart.yaml | sort)
else
  echo "(helm not found - skipping chart rendering)"
fi

if [[ $status -eq 0 ]]; then echo "All manifests valid."; else echo "Validation FAILED."; fi
exit $status
