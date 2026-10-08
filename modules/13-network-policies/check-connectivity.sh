#!/usr/bin/env bash
# Connectivity matrix for module 13: every client pod -> backend:80 and :8080.
#
#   ./modules/13-network-policies/check-connectivity.sh
#
# Each cell is the result of `curl -m 2` from that pod:
#   ok       HTTP response received
#   timeout  packets dropped (this is what a NetworkPolicy block looks like)
#   no-dns   the name didn't resolve (typical for egress policies without DNS)
#   refused  TCP RST (nothing listening - NOT a NetworkPolicy block)
set -u
TARGET="${TARGET:-backend.lab-netpol.svc.cluster.local}"

check() { # <namespace> <pod> <url>
  kubectl -n "$1" exec "$2" -- curl -s -o /dev/null -m 2 "$3" >/dev/null 2>&1
  case $? in
    0) echo ok ;;
    28) echo timeout ;;
    6) echo no-dns ;;
    7) echo refused ;;
    *) echo "error($?)" ;;
  esac
}

printf '%-28s %-9s %-9s\n' "FROM" ":80" ":8080"
for c in lab-netpol/frontend lab-netpol/intruder lab-netpol-other/frontend lab-netpol-other/intruder; do
  ns=${c%/*}; pod=${c#*/}
  printf '%-28s %-9s %-9s\n' "$c" \
    "$(check "$ns" "$pod" "http://$TARGET:80")" \
    "$(check "$ns" "$pod" "http://$TARGET:8080")"
done
