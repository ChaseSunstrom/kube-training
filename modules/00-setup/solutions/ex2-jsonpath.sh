#!/usr/bin/env bash
# Exercise 2 - jsonpath drill (reference solution).
#   bash modules/00-setup/solutions/ex2-jsonpath.sh

# One line per node: name, pod CIDR, kubelet version.
# {range}...{end} loops over .items; {"\t"} and {"\n"} print literal tabs/newlines.
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.podCIDR}{"\t"}{.status.nodeInfo.kubeletVersion}{"\n"}{end}'

echo "---"

# Pods in kube-system on the control-plane node. The field selector filters
# on the server; jsonpath only formats the result.
kubectl get pods -n kube-system \
  --field-selector spec.nodeName=kube-training-control-plane \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'

# The same with custom-columns, which adds a header and aligns the output:
#   kubectl get nodes -o custom-columns=NAME:.metadata.name,CIDR:.spec.podCIDR,KUBELET:.status.nodeInfo.kubeletVersion
