#!/usr/bin/env bash
# verify.sh - checks the capstone acceptance criteria against the running cluster.
#
#   ./modules/19-capstone/verify.sh
#
# It works for YOUR implementation as long as you follow the naming contract in
# the README ("The contract"). It only reads, except for three things, all
# inside lab-capstone: it starts a `kubectl port-forward`, runs one backup Job
# from your CronJob (deleted afterwards), and deletes the db-0 pod once to
# prove the data survives (skip with SKIP_PERSISTENCE=1).
#
# Environment knobs:
#   NS=lab-capstone              namespace to check
#   SKIP_PERSISTENCE=1           don't delete db-0
#   SKIP_NETPOL_ENFORCEMENT=1    report NetworkPolicy *enforcement* failures as
#                                WARN (for CNIs that don't enforce policies)
#   INGRESS_URL=http://capstone.localtest.me   where to test the Ingress
#
# Exit code: 0 if every check passed (warnings allowed), 1 otherwise.
set -u

NS="${NS:-lab-capstone}"
INGRESS_URL="${INGRESS_URL:-http://capstone.localtest.me}"
PASS=0; FAIL=0; WARN=0
PF_PID=""

if [ -t 1 ]; then G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; B=$'\e[1m'; N=$'\e[0m'; else G=; R=; Y=; B=; N=; fi
pass() { PASS=$((PASS+1)); echo "  ${G}PASS${N} $*"; }
fail() { FAIL=$((FAIL+1)); echo "  ${R}FAIL${N} $*"; }
warn() { WARN=$((WARN+1)); echo "  ${Y}WARN${N} $*"; }
section() { echo; echo "${B}$*${N}"; }
k() { kubectl -n "$NS" "$@"; }
# soft check for NetworkPolicy enforcement results
netpol_fail() { if [ "${SKIP_NETPOL_ENFORCEMENT:-0}" = 1 ]; then warn "$*"; else fail "$*"; fi; }

cleanup() {
  [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null
  k delete job -l verify.capstone/manual-backup=true --ignore-not-found >/dev/null 2>&1
}
trap cleanup EXIT

command -v kubectl >/dev/null || { echo "kubectl not found"; exit 1; }
command -v curl >/dev/null    || { echo "curl not found"; exit 1; }

# ---------------------------------------------------------------------------
section "1. Namespace and Pod Security"
if kubectl get ns "$NS" >/dev/null 2>&1; then
  pass "namespace $NS exists"
else
  fail "namespace $NS does not exist - nothing else to check"; exit 1
fi
enf=$(kubectl get ns "$NS" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}')
[ "$enf" = restricted ] && pass "namespace enforces Pod Security 'restricted'" \
                        || fail "namespace label pod-security.kubernetes.io/enforce is '${enf:-unset}', want 'restricted'"

# ---------------------------------------------------------------------------
section "2. Database (StatefulSet db + Secret + PVC + Service)"
if k get statefulset db >/dev/null 2>&1; then
  ready=$(k get sts db -o jsonpath='{.status.readyReplicas}'); want=$(k get sts db -o jsonpath='{.spec.replicas}')
  [ "${ready:-0}" -ge 1 ] && [ "${ready:-0}" = "$want" ] && pass "StatefulSet db ready ($ready/$want)" \
                                                         || fail "StatefulSet db not ready (${ready:-0}/$want)"
  img=$(k get sts db -o jsonpath='{.spec.template.spec.containers[*].image}')
  case "$img" in *postgres:16*) pass "db runs PostgreSQL 16 ($img)";; *) fail "db image is '$img', want postgres:16-alpine";; esac
  vct=$(k get sts db -o jsonpath='{.spec.volumeClaimTemplates[*].metadata.name}')
  [ -n "$vct" ] && pass "db uses volumeClaimTemplates ($vct)" || fail "db has no volumeClaimTemplates (data would not persist)"
  for c in $vct; do
    st=$(k get pvc "$c-db-0" -o jsonpath='{.status.phase}' 2>/dev/null)
    [ "$st" = Bound ] && pass "PVC $c-db-0 is Bound" || fail "PVC $c-db-0 is '${st:-missing}'"
  done
  # Password must come from a Secret, never a literal value.
  pw_literal=$(k get sts db -o jsonpath='{range .spec.template.spec.containers[*].env[?(@.name=="POSTGRES_PASSWORD")]}{.value}{end}')
  pw_ref=$(k get sts db -o jsonpath='{.spec.template.spec.containers[*].env[?(@.name=="POSTGRES_PASSWORD")].valueFrom.secretKeyRef.name}{.spec.template.spec.containers[*].envFrom[*].secretRef.name}')
  if [ -n "$pw_literal" ]; then
    fail "POSTGRES_PASSWORD is a literal value in the StatefulSet - use a Secret"
  elif [ -n "$pw_ref" ]; then
    pass "credentials come from Secret(s): $pw_ref"
  else
    fail "could not find where POSTGRES_PASSWORD comes from (expected secretKeyRef or envFrom secretRef)"
  fi
else
  fail "StatefulSet db not found"
fi
port=$(k get svc db -o jsonpath='{.spec.ports[*].port}' 2>/dev/null)
case " $port " in *" 5432 "*) pass "Service db exposes 5432";; *) fail "Service db with port 5432 not found";; esac

# ---------------------------------------------------------------------------
section "3. Seed Job and data"
succ=$(k get job db-seed -o jsonpath='{.status.succeeded}' 2>/dev/null)
[ "${succ:-0}" -ge 1 ] && pass "Job db-seed succeeded" || fail "Job db-seed missing or not succeeded"
count_items() {
  k exec db-0 -c "$(k get pod db-0 -o jsonpath='{.spec.containers[0].name}')" -- \
    sh -c 'psql -X -q -t -A -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-${POSTGRES_USER:-postgres}}" -c "SELECT count(*) FROM items"' 2>/dev/null | tr -d '[:space:]'
}
rows=$(count_items)
[ "${rows:-0}" -ge 3 ] 2>/dev/null && pass "table items has $rows rows" || fail "table items has '${rows:-?}' rows, want >= 3"

# ---------------------------------------------------------------------------
section "4. Backend (Deployment backend + Service + PDB + HPA)"
if k get deploy backend >/dev/null 2>&1; then
  av=$(k get deploy backend -o jsonpath='{.status.availableReplicas}')
  [ "${av:-0}" -ge 2 ] && pass "backend has $av available replicas" || fail "backend has ${av:-0} available replicas, want >= 2"
  probes=$(k get deploy backend -o jsonpath='{range .spec.template.spec.containers[*]}{.name}:{.readinessProbe.periodSeconds}{.readinessProbe.httpGet.port}{.readinessProbe.tcpSocket.port}{.readinessProbe.exec.command[0]}:{.livenessProbe.periodSeconds}{.livenessProbe.httpGet.port}{.livenessProbe.tcpSocket.port}{.livenessProbe.exec.command[0]}{"\n"}{end}')
  bad=$(echo "$probes" | awk -F: 'NF && ($2=="" || $3=="") {print $1}')
  [ -z "$bad" ] && pass "every backend container has readiness and liveness probes" || fail "containers without readiness/liveness probe: $bad"
else
  fail "Deployment backend not found"
fi
k get svc backend >/dev/null 2>&1 && pass "Service backend exists" || fail "Service backend not found"
pdb=$(k get pdb -o jsonpath='{range .items[?(@.spec.selector.matchLabels.app=="backend")]}{.metadata.name}{end}')
[ -n "$pdb" ] && pass "PodDisruptionBudget for backend: $pdb" || fail "no PodDisruptionBudget selecting app=backend"
hpa=$(k get hpa -o jsonpath='{range .items[?(@.spec.scaleTargetRef.name=="backend")]}{.metadata.name}:{.spec.minReplicas}:{.spec.maxReplicas}{end}')
if [ -n "$hpa" ]; then
  min=$(echo "$hpa" | cut -d: -f2)
  [ "${min:-1}" -ge 2 ] && pass "HPA for backend (min/max: $(echo "$hpa" | cut -d: -f2-))" || fail "HPA for backend has minReplicas ${min:-1}, want >= 2"
  cur=$(k get hpa "${hpa%%:*}" -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}')
  [ -n "$cur" ] || warn "HPA has no metrics yet (is metrics-server installed? module 14)"
else
  fail "no HorizontalPodAutoscaler targeting backend"
fi

# ---------------------------------------------------------------------------
section "5. Frontend (Deployment frontend + nginx config from a ConfigMap)"
if k get deploy frontend >/dev/null 2>&1; then
  av=$(k get deploy frontend -o jsonpath='{.status.availableReplicas}')
  [ "${av:-0}" -ge 2 ] && pass "frontend has $av available replicas" || fail "frontend has ${av:-0} available replicas, want >= 2"
  img=$(k get deploy frontend -o jsonpath='{.spec.template.spec.containers[*].image}')
  case "$img" in *nginx:1.27-alpine*) pass "frontend runs $img";; *) fail "frontend image is '$img', want nginx:1.27-alpine";; esac
  cms=$(k get deploy frontend -o jsonpath='{.spec.template.spec.volumes[*].configMap.name}')
  [ -n "$cms" ] && pass "frontend mounts ConfigMap(s): $cms" || fail "frontend mounts no ConfigMap (nginx config should come from one)"
else
  fail "Deployment frontend not found"
fi
k get svc frontend >/dev/null 2>&1 && pass "Service frontend exists" || fail "Service frontend not found"

# ---------------------------------------------------------------------------
section "6. Resources and security context on every workload container"
list_containers() {
  k get deploy,statefulset,job -o jsonpath='{range .items[*]}{range .spec.template.spec.containers[*]}{.name}|{.resources.requests.cpu}|{.resources.requests.memory}|{.resources.limits.memory}|{.securityContext.readOnlyRootFilesystem}|{.securityContext.allowPrivilegeEscalation}{"\n"}{end}{end}'
  k get cronjob -o jsonpath='{range .items[*]}{range .spec.jobTemplate.spec.template.spec.containers[*]}{.name}|{.resources.requests.cpu}|{.resources.requests.memory}|{.resources.limits.memory}|{.securityContext.readOnlyRootFilesystem}|{.securityContext.allowPrivilegeEscalation}{"\n"}{end}{end}'
}
rows_c=$(list_containers | grep -v '^$')
nores=$(echo "$rows_c" | awk -F'|' '$2=="" || $3=="" || $4=="" {print $1}' | sort -u | tr '\n' ' ')
[ -z "$nores" ] && pass "all $(echo "$rows_c" | wc -l | tr -d ' ') containers set requests.cpu, requests.memory and limits.memory" \
                || fail "containers missing requests/limits: $nores"
norofs=$(echo "$rows_c" | awk -F'|' '$5!="true" {print $1}' | sort -u | tr '\n' ' ')
[ -z "$norofs" ] && pass "all containers use readOnlyRootFilesystem" || fail "containers without readOnlyRootFilesystem: $norofs"
nope=$(echo "$rows_c" | awk -F'|' '$6!="false" {print $1}' | sort -u | tr '\n' ' ')
[ -z "$nope" ] && pass "all containers set allowPrivilegeEscalation: false" || fail "containers without allowPrivilegeEscalation=false: $nope"

# ---------------------------------------------------------------------------
section "7. End to end through the frontend (via kubectl port-forward)"
LPORT=$(( 20000 + RANDOM % 20000 ))
k port-forward svc/frontend "$LPORT:80" >/dev/null 2>&1 &
PF_PID=$!
for _ in $(seq 1 30); do curl -s -o /dev/null "http://127.0.0.1:$LPORT/" && break; sleep 0.5; done
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$LPORT/")
[ "$code" = 200 ] && pass "GET / -> 200" || fail "GET / -> $code"
body=$(curl -s --max-time 5 "http://127.0.0.1:$LPORT/api/items")
n=$(printf '%s' "$body" | grep -o '"name"' | wc -l | tr -d ' ')
[ "${n:-0}" -ge 3 ] && pass "GET /api/items returns $n items from the database" \
                    || fail "GET /api/items did not return >= 3 items: $(printf '%s' "$body" | head -c 200)"
kill "$PF_PID" 2>/dev/null; PF_PID=""

# ---------------------------------------------------------------------------
section "8. NetworkPolicies"
dd=$(k get netpol -o jsonpath='{range .items[*]}{.metadata.name}|{.spec.podSelector}|{.spec.policyTypes}{"\n"}{end}' | awk -F'|' '$2=="{}" && $3 ~ /Ingress/ && $3 ~ /Egress/ {print $1}')
[ -n "$dd" ] && pass "default-deny policy for ingress+egress: $dd" || fail "no policy with podSelector {} denying both Ingress and Egress"
FE=$(k get pod -l app=frontend -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
BE=$(k get pod -l app=backend  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "$FE" ] && [ -n "$BE" ]; then
  # (busybox nslookup ignores the search path, so use the full name)
  k exec "$FE" -- nslookup "backend.$NS.svc.cluster.local" >/dev/null 2>&1 \
    && pass "DNS works from frontend" || fail "DNS lookup of backend.$NS.svc.cluster.local fails from frontend (allow egress to kube-dns on 53/UDP+TCP)"
  k exec "$FE" -- wget -q -O /dev/null -T 3 http://backend:8080/api/health >/dev/null 2>&1 \
    && pass "frontend -> backend:8080 allowed" || fail "frontend -> backend:8080 is blocked"
  k exec "$BE" -- sh -c 'nc -z -w 3 db 5432' >/dev/null 2>&1 \
    && pass "backend -> db:5432 allowed" || fail "backend -> db:5432 is blocked"
  if k exec "$FE" -- nc -z -w 3 db 5432 >/dev/null 2>&1; then
    netpol_fail "frontend -> db:5432 is OPEN (should be blocked; is a policy missing, or does your CNI not enforce NetworkPolicy? module 13)"
  else
    pass "frontend -> db:5432 blocked"
  fi
  if k exec "$BE" -- sh -c 'nc -z -w 3 frontend 80' >/dev/null 2>&1; then
    netpol_fail "backend -> frontend:80 is OPEN (backend should only talk to db and DNS)"
  else
    pass "backend -> frontend blocked"
  fi
else
  fail "no frontend/backend pods to test from"
fi

# ---------------------------------------------------------------------------
section "9. Ingress"
ing=$(k get ingress -o jsonpath='{range .items[*]}{range .spec.rules[*]}{.host}|{.http.paths[*].backend.service.name}{"\n"}{end}{end}' | grep '^capstone.localtest.me|')
case "$ing" in *frontend*) pass "Ingress routes capstone.localtest.me to Service frontend";; *) fail "no Ingress rule for host capstone.localtest.me -> frontend";; esac
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$INGRESS_URL/api/items" 2>/dev/null)
[ "$code" = 200 ] && pass "$INGRESS_URL/api/items -> 200 through the ingress controller" \
                  || warn "$INGRESS_URL/api/items -> ${code:-no answer} (no ingress controller on localhost:80? module 12)"

# ---------------------------------------------------------------------------
section "10. Backups (CronJob db-backup)"
if k get cronjob db-backup >/dev/null 2>&1; then
  pvc=$(k get cronjob db-backup -o jsonpath='{.spec.jobTemplate.spec.template.spec.volumes[*].persistentVolumeClaim.claimName}')
  [ -n "$pvc" ] && pass "CronJob db-backup writes to PVC $pvc" || fail "CronJob db-backup mounts no PVC"
  job="verify-backup-$(date +%s)"
  if k create job --from=cronjob/db-backup "$job" >/dev/null 2>&1; then
    k label job "$job" verify.capstone/manual-backup=true >/dev/null 2>&1
    if k wait --for=condition=complete "job/$job" --timeout=180s >/dev/null 2>&1; then
      pass "a backup run from the CronJob completed: $(k logs "job/$job" 2>/dev/null | grep -m1 -iE 'backup|dump' || echo ok)"
    else
      fail "backup Job $job did not complete within 180s (kubectl -n $NS describe job $job)"
    fi
  else
    fail "could not create a Job from cronjob/db-backup"
  fi
else
  fail "CronJob db-backup not found"
fi

# ---------------------------------------------------------------------------
section "11. Data survives a database pod restart"
if [ "${SKIP_PERSISTENCE:-0}" = 1 ]; then
  warn "skipped (SKIP_PERSISTENCE=1)"
else
  uid_before=$(k get pod db-0 -o jsonpath='{.metadata.uid}')
  k delete pod db-0 --wait=true >/dev/null 2>&1
  for _ in $(seq 1 60); do
    uid_now=$(k get pod db-0 -o jsonpath='{.metadata.uid}' 2>/dev/null)
    [ -n "$uid_now" ] && [ "$uid_now" != "$uid_before" ] && break; sleep 2
  done
  k wait --for=condition=Ready pod/db-0 --timeout=180s >/dev/null 2>&1
  rows=$(count_items)
  [ "${rows:-0}" -ge 3 ] 2>/dev/null && pass "db-0 was recreated and still has $rows rows" \
                                     || fail "after recreating db-0 the items table has '${rows:-?}' rows"
fi

# ---------------------------------------------------------------------------
echo
echo "${B}Result:${N} ${G}${PASS} passed${N}, ${R}${FAIL} failed${N}, ${Y}${WARN} warnings${N}"
[ "$FAIL" -eq 0 ]
