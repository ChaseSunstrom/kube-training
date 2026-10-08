#!/usr/bin/env bash
# End-to-end test for every pattern in this scenario.
#
#   ./test.sh            # run all four patterns
#   ./test.sh 1 3        # run only patterns 1 and 3
#   KEEP=1 ./test.sh 2   # leave the namespace running afterwards so you can poke at it
#
# For each pattern it applies pod B BEFORE pod A where that makes sense, to
# prove the ordering is enforced by the cluster and not by `kubectl apply`
# order, then asserts:
#   * pod B's app container started only after pod A finished / became Ready
#   * every pod using the RWO claim ran on the same node
#   * the Service in front of pod B serves the data pod A wrote
#
# Needs: bash, kubectl pointed at a cluster with a default StorageClass
# (e.g. `make cluster-up`).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIMEOUT="${TIMEOUT:-300s}"
KEEP="${KEEP:-0}"
FAILURES=0

c_green=$'\e[32m'; c_red=$'\e[31m'; c_blue=$'\e[34m'; c_off=$'\e[0m'
[ -t 1 ] || { c_green=""; c_red=""; c_blue=""; c_off=""; }

log()  { echo "${c_blue}==>${c_off} $*"; }
pass() { echo "  ${c_green}PASS${c_off} $*"; }
fail() { echo "  ${c_red}FAIL${c_off} $*"; FAILURES=$((FAILURES + 1)); }

# ISO-8601 UTC timestamps sort lexicographically.
assert_not_before() { # <label> <earlier> <later>
  local label="$1" earlier="$2" later="$3"
  if [[ -z "$earlier" || -z "$later" ]]; then
    fail "$label (missing timestamp: '$earlier' / '$later')"
  elif [[ "$later" < "$earlier" ]]; then
    fail "$label ($later is before $earlier)"
  else
    pass "$label ($earlier <= $later)"
  fi
}

assert_same_node() { # <namespace>  (all pods currently using the claim)
  local ns="$1" nodes
  nodes="$(kubectl -n "$ns" get pods -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort -u | grep -c . || true)"
  if [[ "$nodes" == "1" ]]; then
    pass "all pods ran on one node ($(kubectl -n "$ns" get pods -o jsonpath='{.items[0].spec.nodeName}'))"
  else
    fail "pods are spread over $nodes nodes:"; kubectl -n "$ns" get pods -o wide
  fi
}

assert_http_contains() { # <namespace> <exec-target> <url> <expected text>
  local ns="$1" target="$2" url="$3" want="$4" body
  body="$(kubectl -n "$ns" exec "$target" -- wget -qO- -T 5 "$url" 2>&1 || true)"
  if grep -q "$want" <<<"$body"; then
    pass "GET $url contains '$want'"
  else
    fail "GET $url did not contain '$want'. Got: $body"
  fi
}

wait_for_pod() { # <namespace> <label selector>  - wait until a pod matching exists
  local ns="$1" sel="$2" i
  for i in $(seq 1 60); do
    [[ -n "$(kubectl -n "$ns" get pods -l "$sel" -o name 2>/dev/null)" ]] && return 0
    sleep 1
  done
  fail "no pod matching '$sel' appeared in $ns"; return 1
}

fresh_ns() { # <namespace> - wait for a leftover namespace from an earlier run to finish terminating
  if kubectl get namespace "$1" >/dev/null 2>&1; then
    log "namespace $1 already exists - deleting it for a clean run"
    kubectl delete namespace "$1" --wait=true --timeout=180s >/dev/null
  fi
}

cleanup() { # <namespace>
  if [[ "$KEEP" == "1" ]]; then
    log "KEEP=1 -> leaving namespace $1 in place (kubectl delete namespace $1)"
  else
    kubectl delete namespace "$1" --ignore-not-found --wait=true --timeout=180s >/dev/null
  fi
}

# --------------------------------------------------------------------------
pattern_1() {
  local d="$HERE/1-sequential-job-then-app" ns=lab-rwo-sequential
  log "Pattern 1: sequential hand-off (Job -> Deployment), applying pod B FIRST"
  fresh_ns "$ns"
  kubectl apply -f "$d/00-namespace.yaml" -f "$d/01-pvc.yaml" -f "$d/02-rbac.yaml" \
                -f "$d/04-deployment-web.yaml" -f "$d/05-service.yaml" >/dev/null
  wait_for_pod "$ns" app=web
  sleep 5   # give pod B a head start: it must sit in Init and wait
  echo "  pod B before pod A exists: $(kubectl -n "$ns" get pods -l app=web --no-headers | awk '{print $3}')"
  kubectl apply -f "$d/03-job-seed.yaml" >/dev/null

  kubectl -n "$ns" wait --for=condition=complete job/seed --timeout="$TIMEOUT" >/dev/null
  kubectl -n "$ns" wait --for=condition=Available deployment/web --timeout="$TIMEOUT" >/dev/null

  local job_done web_started
  job_done="$(kubectl -n "$ns" get job seed -o jsonpath='{.status.completionTime}')"
  web_started="$(kubectl -n "$ns" get pod -l app=web -o jsonpath='{.items[0].status.containerStatuses[0].state.running.startedAt}')"
  assert_not_before "web started after the seed Job completed" "$job_done" "$web_started"
  assert_same_node "$ns"
  assert_http_contains "$ns" deploy/web http://web "Hello from the shared RWO volume"
  cleanup "$ns"
}

pattern_2() {
  local d="$HERE/2-concurrent-ordered-start" ns=lab-rwo-concurrent
  log "Pattern 2: concurrent sharing with ordered start (writer Ready -> web), applying pod B FIRST"
  fresh_ns "$ns"
  kubectl apply -f "$d/00-namespace.yaml" -f "$d/01-pvc.yaml" -f "$d/03-service-writer.yaml" \
                -f "$d/04-deployment-web.yaml" -f "$d/05-service-web.yaml" >/dev/null
  wait_for_pod "$ns" app=web
  sleep 5
  echo "  pod B before pod A exists: $(kubectl -n "$ns" get pods -l app=web --no-headers | awk '{print $3}')"
  kubectl apply -f "$d/02-deployment-writer.yaml" >/dev/null

  kubectl -n "$ns" wait --for=condition=Available deployment/writer deployment/web --timeout="$TIMEOUT" >/dev/null

  local writer_ready web_started
  writer_ready="$(kubectl -n "$ns" get pod -l app=writer -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].lastTransitionTime}')"
  web_started="$(kubectl -n "$ns" get pod -l app=web -o jsonpath='{.items[0].status.containerStatuses[0].state.running.startedAt}')"
  assert_not_before "web started after the writer became Ready" "$writer_ready" "$web_started"
  assert_same_node "$ns"
  assert_http_contains "$ns" deploy/web http://web "concurrent writer + reader"
  sleep 6   # at least one more heartbeat
  assert_http_contains "$ns" deploy/web http://web/heartbeat.txt "heartbeat from writer-"
  cleanup "$ns"
}

pattern_3() {
  local d="$HERE/3-statefulset-ordered" ns=lab-rwo-statefulset
  log "Pattern 3: StatefulSet OrderedReady (app-0 Ready -> app-1 created)"
  fresh_ns "$ns"
  kubectl apply -f "$d/" >/dev/null
  kubectl -n "$ns" rollout status statefulset/app --timeout="$TIMEOUT" >/dev/null

  local p0_ready p1_created
  p0_ready="$(kubectl -n "$ns" get pod app-0 -o jsonpath='{.status.conditions[?(@.type=="Ready")].lastTransitionTime}')"
  p1_created="$(kubectl -n "$ns" get pod app-1 -o jsonpath='{.metadata.creationTimestamp}')"
  assert_not_before "app-1 was created after app-0 became Ready" "$p0_ready" "$p1_created"
  assert_same_node "$ns"
  assert_http_contains "$ns" pod/app-1 http://app/startup-order.txt "app-1 (ordinal 1)"
  local order
  order="$(kubectl -n "$ns" exec app-0 -- cat /data/www/startup-order.txt | awk '{print $2}' | tr '\n' ' ')"
  [[ "$order" == "app-0 app-1 " ]] && pass "startup-order.txt lists app-0 then app-1" \
                                  || fail "unexpected start-up order: $order"
  cleanup "$ns"
}

pattern_4() {
  local d="$HERE/4-rwop-strict-handoff" ns=lab-rwo-rwop
  log "Pattern 4: ReadWriteOncePod strict hand-off (seed Job scales web 0 -> 1)"
  fresh_ns "$ns"
  kubectl apply -f "$d/" >/dev/null
  kubectl -n "$ns" wait --for=condition=complete job/seed --timeout="$TIMEOUT" >/dev/null
  kubectl -n "$ns" wait --for=condition=Available deployment/web --timeout="$TIMEOUT" >/dev/null

  local seed_done seed_pod_end web_started
  seed_done="$(kubectl -n "$ns" get pod -l app=seed -o jsonpath='{.items[0].status.initContainerStatuses[0].state.terminated.finishedAt}')"
  seed_pod_end="$(kubectl -n "$ns" get pod -l app=seed -o jsonpath='{.items[0].status.containerStatuses[0].state.terminated.finishedAt}')"
  web_started="$(kubectl -n "$ns" get pod -l app=web -o jsonpath='{.items[0].status.containerStatuses[0].state.running.startedAt}')"
  assert_not_before "web started after seed finished writing" "$seed_done" "$web_started"
  assert_not_before "web started after the seed pod released the RWOP claim" "$seed_pod_end" "$web_started"
  if kubectl -n "$ns" get events --field-selector reason=FailedScheduling -o jsonpath='{.items[*].message}' | grep -q ReadWriteOncePod; then
    pass "scheduler kept web Pending while the seed pod held the claim (FailedScheduling: ReadWriteOncePod)"
  else
    echo "  info: no ReadWriteOncePod FailedScheduling event seen (seed finished before web was scheduled - fine)"
  fi
  assert_http_contains "$ns" deploy/web http://web "ReadWriteOncePod hand-off"
  cleanup "$ns"
}

# --------------------------------------------------------------------------
patterns=("$@")
[[ ${#patterns[@]} -eq 0 ]] && patterns=(1 2 3 4)
for p in "${patterns[@]}"; do
  case "$p" in
    1|2|3|4) "pattern_$p" ;;
    *) echo "unknown pattern '$p' (use 1, 2, 3 or 4)"; exit 2 ;;
  esac
done

if [[ "$FAILURES" -eq 0 ]]; then
  echo "${c_green}All checks passed.${c_off}"
else
  echo "${c_red}$FAILURES check(s) failed.${c_off}"; exit 1
fi
