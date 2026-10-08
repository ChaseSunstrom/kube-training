#!/usr/bin/env bash
# Connectivity matrix for module 13: every client pod -> backend.
#
#   ./modules/13-network-policies/check-connectivity.sh
#
# Columns (each test runs INSIDE the client pod, with a 2-3 s timeout):
#   dns    can the pod resolve backend.lab-netpol.svc.cluster.local?
#          (needs egress to CoreDNS on port 53)
#   :80    HTTP to the backend Service IP, port 80  (whoami "http")
#   :8080  HTTP to the backend Service IP, port 8080 (whoami "admin")
# The HTTP tests use the Service IP, not the name, so a DNS problem doesn't
# hide the result of the port test.
#
#   ok       it worked
#   blocked  no connection. Most NetworkPolicy implementations (kindnet,
#            Calico, Cilium) silently DROP packets, so curl just times out;
#            a few REJECT them and curl reports "connection refused".
#            Both show up here as "blocked".
set -u
NAME=backend.lab-netpol.svc.cluster.local
IP=$(kubectl -n lab-netpol get service backend -o jsonpath='{.spec.clusterIP}')

dns()  { kubectl -n "$1" exec "$2" -- timeout 3 nslookup "$NAME" >/dev/null 2>&1 && echo ok || echo FAIL; }
http() { kubectl -n "$1" exec "$2" -- curl -s -o /dev/null -m 2 "http://$IP:$3" >/dev/null 2>&1 && echo ok || echo blocked; }

printf '%-28s %-6s %-9s %-9s\n' "FROM" "dns" ":80" ":8080"
for c in lab-netpol/frontend lab-netpol/intruder lab-netpol-other/frontend lab-netpol-other/intruder; do
  ns=${c%/*}; pod=${c#*/}
  printf '%-28s %-6s %-9s %-9s\n' "$c" "$(dns "$ns" "$pod")" "$(http "$ns" "$pod" 80)" "$(http "$ns" "$pod" 8080)"
done
