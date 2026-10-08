# Module 13 – NetworkPolicies

## Goal

Turn the cluster's flat "every pod can reach every pod" network into explicit
allow-lists for incoming and outgoing traffic – and know the gotchas that
break real-world policies (DNS, AND vs OR, Service ports, Service IPs).

## What you'll learn

* Default-allow, and what makes a pod "isolated"
* Default-deny ingress, then allow by pod label, by namespace, and by both
* The `namespaceSelector` + `podSelector` **AND vs OR** YAML trap
* Default-deny egress and the **DNS gotcha**
* Port rules (numbers, named ports) and why Service ports don't count
* `ipBlock` for non-pod destinations (the API server) and its gotchas
* How to check that your cluster actually **enforces** NetworkPolicy

## Concepts

### Who enforces NetworkPolicy?

A NetworkPolicy is just an object in the API. **The CNI plugin** (or an
add-on next to it) turns it into packet filters. If your network plugin
doesn't implement NetworkPolicy, the API server happily accepts every policy
and **nothing is blocked** – no error, no warning.

| Plugin | Enforces NetworkPolicy? |
|---|---|
| kindnet (kind's default CNI), kind ≥ v0.24 | yes, via its built-in `kube-network-policies` engine (nftables + NFQUEUE; needs a host kernel with nftables queue support) |
| Calico, Cilium, Antrea, kube-router | yes |
| flannel (alone), many "simple" CNIs | **no** |

Lab step 2 is a quick enforcement test. Do it on every new cluster before you
trust a policy.

### The model in five sentences

1. With **no** policy selecting a pod, the pod accepts all traffic and may
   send to anywhere ("default allow").
2. A pod becomes **isolated for ingress** (or egress) as soon as **any**
   policy that selects it lists `Ingress` (or `Egress`) in `policyTypes`.
3. An isolated pod only gets traffic that **some** policy explicitly allows.
   Policies are **additive allow-lists**: there are no deny rules, no
   priorities, no order. (Cluster-wide rules written by admins, including
   explicit denies, are the subject of SIG Network's separate *Network Policy
   API* project – AdminNetworkPolicy and its successors – which some CNIs
   implement as CRDs.)
4. A connection needs permission on **both** ends: egress from the client
   pod **and** ingress to the server pod (if either side is isolated).
5. Policies are **stateful**: replies to an allowed connection always get
   back; only the side that *opens* the connection is checked.

### Anatomy

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: backend-allow-frontend
  namespace: lab-netpol          # policies are namespaced ...
spec:
  podSelector:                   # ... and apply to these pods of that namespace
    matchLabels: {app: backend}  # {} = every pod in the namespace
  policyTypes: [Ingress]         # which directions this policy isolates
  ingress:                       # list of rules - a packet needs to match ONE rule
    - from:                      # list of peers - ONE must match (OR)
        - podSelector: {matchLabels: {app: frontend}}
      ports:                     # AND the port must match one of these
        - {protocol: TCP, port: 80}
```

Peers in `from` / `to`:

| Peer | Matches |
|---|---|
| `podSelector` | pods in the **policy's own namespace** |
| `namespaceSelector` | all pods in namespaces whose **labels** match (`{}` = all namespaces) |
| `namespaceSelector` + `podSelector` **in the same element** | pods matching the pod selector **in** namespaces matching the namespace selector (AND) |
| `ipBlock` (`cidr`, `except`) | IP ranges – meant for traffic from/to **outside** the cluster |

Every namespace carries the immutable label
`kubernetes.io/metadata.name: <name>`, so you can select a namespace by name
without labelling it yourself.

### AND vs OR – one dash

```yaml
# AND: pods labelled app=frontend IN lab-netpol-other         (06)
- from:
    - namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: lab-netpol-other}}
      podSelector:       {matchLabels: {app: frontend}}

# OR: ANY pod in lab-netpol-other, OR app=frontend pods in the policy's own namespace   (07)
- from:
    - namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: lab-netpol-other}}
    - podSelector:       {matchLabels: {app: frontend}}
```

`kubectl describe networkpolicy` shows the difference clearly (step 6) – use
it to double-check every policy you write.

### Ports and addresses are the ones the POD sees

* `ports` are matched against the **pod's** port (the Service's
  `targetPort`), never the Service port. Named ports (`port: http`) are
  resolved per pod.
* Traffic to a Service IP is translated to a pod (or node) IP by kube-proxy.
  The spec leaves it implementation-defined whether policies see the address
  before or after that translation; in practice kindnet, Calico and Cilium
  see the **translated** address. So: select **pods** with selectors, and for
  non-pod endpoints (the API server) use the endpoint's real IP and port.

## Files

| File | What it demonstrates |
|---|---|
| [`00-namespaces.yaml`](00-namespaces.yaml) | `lab-netpol` and `lab-netpol-other` |
| [`01-backend.yaml`](01-backend.yaml) | The server: whoami on port 80 (`http`) and 8080 (`admin`) + Service |
| [`02-clients.yaml`](02-clients.yaml) | `frontend` and `intruder` client pods in both namespaces |
| [`check-connectivity.sh`](check-connectivity.sh) | Prints the client → backend matrix (DNS, :80, :8080) |
| [`03-default-deny-ingress.yaml`](03-default-deny-ingress.yaml) | Isolate every pod in `lab-netpol` for ingress |
| [`04-allow-frontend.yaml`](04-allow-frontend.yaml) | Allow `app=frontend` (same namespace) to backend's named port `http` |
| [`05-allow-from-namespace.yaml`](05-allow-from-namespace.yaml) | Allow every pod of `lab-netpol-other` |
| [`06-and-selector.yaml`](06-and-selector.yaml) | namespaceSelector AND podSelector |
| [`07-or-selector.yaml`](07-or-selector.yaml) | The same selectors as OR – the gotcha |
| [`08-default-deny-egress.yaml`](08-default-deny-egress.yaml) | Isolate every pod in `lab-netpol` for egress (breaks DNS!) |
| [`09-allow-dns-egress.yaml`](09-allow-dns-egress.yaml) | Allow UDP+TCP 53 to CoreDNS |
| [`10-allow-egress-to-backend.yaml`](10-allow-egress-to-backend.yaml) | Client-side egress rule frontend → backend:80 |
| [`11-ipblock-egress.yaml`](11-ipblock-egress.yaml) | `ipBlock` to reach the API server (node IP, port 6443) |
| [`exercises/`](exercises/) / [`solutions/`](solutions/) | Exercises and reference answers |

## Lab

Run everything from the repo root. The policies stay in place from step to
step unless a step deletes them, exactly like on a real cluster – so the
matrix after each step shows the effect of **all** policies applied so far.

### 1. Default allow

```bash
kubectl apply -f modules/13-network-policies/00-namespaces.yaml \
              -f modules/13-network-policies/01-backend.yaml \
              -f modules/13-network-policies/02-clients.yaml
kubectl -n lab-netpol rollout status deployment backend
kubectl wait --for=condition=Ready pod --all -n lab-netpol
kubectl wait --for=condition=Ready pod --all -n lab-netpol-other

kubectl get ns lab-netpol-other --show-labels
kubectl -n lab-netpol exec frontend -- curl -s -m 3 http://backend
./modules/13-network-policies/check-connectivity.sh
```

```
NAME               STATUS   AGE   LABELS
lab-netpol-other   Active   2s    app=lab-netpol,kubernetes.io/metadata.name=lab-netpol-other

Name: backend-http
Hostname: backend-645785454c-55sjl
IP: 127.0.0.1
IP: 10.244.0.10
RemoteAddr: 10.244.0.11:46080
GET / HTTP/1.1
Host: backend
...

FROM                         dns    :80       :8080
lab-netpol/frontend          ok     ok        ok
lab-netpol/intruder          ok     ok        ok
lab-netpol-other/frontend    ok     ok        ok
lab-netpol-other/intruder    ok     ok        ok
```

Note the automatic `kubernetes.io/metadata.name` label. Without any policy,
everyone reaches everything – including the "admin" port 8080.

### 2. Default deny ingress – and the enforcement check

```bash
kubectl apply -f modules/13-network-policies/03-default-deny-ingress.yaml
./modules/13-network-policies/check-connectivity.sh
```

```
FROM                         dns    :80       :8080
lab-netpol/frontend          ok     blocked   blocked
lab-netpol/intruder          ok     blocked   blocked
lab-netpol-other/frontend    ok     blocked   blocked
lab-netpol-other/intruder    ok     blocked   blocked
```

Every pod in `lab-netpol` is now isolated for ingress, and nothing is allowed.
DNS still works (the clients' egress isn't restricted, and CoreDNS lives in
`kube-system`). With kindnet a blocked connection simply hangs until curl's
timeout – the packets are dropped, not rejected.

> **If you still see `ok` everywhere, your cluster doesn't enforce
> NetworkPolicy.** On kind, check kindnet's policy engine:
>
> ```bash
> kubectl -n kube-system logs -l app=kindnet --tail=-1 --prefix | grep -E 'kube-network-policies|Policy engine|nftables sync'
> ```
>
> ```
> [pod/kindnet-fn6hz/kindnet-cni] ... "Starting controller" name="kube-network-policies"
> [pod/kindnet-fn6hz/kindnet-cni] ... "Policy engine is ready."
> [pod/kindnet-fn6hz/kindnet-cni] ... "initial nftables sync failed" err=< ...
> ```
>
> `initial nftables sync failed` means the host kernel lacks something the
> engine needs (typically nftables `queue` support: the `nft_queue` /
> `nfnetlink_queue` modules). A kind older than v0.24 has no policy engine at
> all – upgrade. If you can't fix the host, run this module on a second kind
> cluster that uses **Calico** instead of kindnet (see *Calico fallback*
> below), then redo step 1 there.

#### Calico fallback (only if step 2 showed no enforcement)

```bash
cat <<EOF | kind create cluster --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: kube-training-calico
networking:
  disableDefaultCNI: true        # don't install kindnet
  podSubnet: 192.168.0.0/16      # Calico's default IP pool
nodes:
  - role: control-plane
  - role: worker
    labels: {training/zone: zone-a}
  - role: worker
    labels: {training/zone: zone-b}
EOF
# kind switches your kubectl context to kind-kube-training-calico.
# Nodes stay NotReady until a CNI is installed:
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.32.2/manifests/calico.yaml
kubectl -n kube-system rollout status daemonset/calico-node --timeout=300s
kubectl get nodes                                    # all Ready
```

The cluster has no host port mappings, so it can run next to the main
training cluster. Switch back with `kubectl config use-context kind-kube-training`
when you're done (and see *Cleanup*).

### 3. Allow by pod label

```bash
kubectl apply -f modules/13-network-policies/04-allow-frontend.yaml
./modules/13-network-policies/check-connectivity.sh
```

```
FROM                         dns    :80       :8080
lab-netpol/frontend          ok     ok        blocked
lab-netpol/intruder          ok     blocked   blocked
lab-netpol-other/frontend    ok     blocked   blocked
lab-netpol-other/intruder    ok     blocked   blocked
```

Three lessons in one table:

* `intruder` is blocked: wrong label.
* `lab-netpol-other/frontend` is blocked **despite the right label**: a
  `podSelector` without `namespaceSelector` only matches pods in the policy's
  own namespace.
* Port 8080 stays closed even for `frontend`: the rule only lists the named
  port `http` (= 80).

### 4. Allow a whole namespace

```bash
kubectl apply -f modules/13-network-policies/05-allow-from-namespace.yaml
./modules/13-network-policies/check-connectivity.sh
```

```
FROM                         dns    :80       :8080
lab-netpol/frontend          ok     ok        blocked
lab-netpol/intruder          ok     blocked   blocked
lab-netpol-other/frontend    ok     ok        blocked
lab-netpol-other/intruder    ok     ok        blocked
```

Policies add up: frontend still gets in through 04, and every pod of
`lab-netpol-other` through 05. Remove it again:

```bash
kubectl delete -f modules/13-network-policies/05-allow-from-namespace.yaml
```

### 5. namespaceSelector AND podSelector

```bash
kubectl apply -f modules/13-network-policies/06-and-selector.yaml
./modules/13-network-policies/check-connectivity.sh
kubectl -n lab-netpol describe networkpolicy backend-allow-other-frontend-and
```

```
FROM                         dns    :80       :8080
lab-netpol/frontend          ok     ok        blocked
lab-netpol/intruder          ok     blocked   blocked
lab-netpol-other/frontend    ok     ok        blocked
lab-netpol-other/intruder    ok     blocked   blocked

Spec:
  PodSelector:     app=backend
  Allowing ingress traffic:
    To Port: 80/TCP
    From:
      NamespaceSelector: kubernetes.io/metadata.name=lab-netpol-other
      PodSelector: app=frontend
  Not affecting egress traffic
  Policy Types: Ingress
```

Only `lab-netpol-other/frontend` got in: both conditions in **one** `From`
block. Delete it before the next step:

```bash
kubectl delete -f modules/13-network-policies/06-and-selector.yaml
```

### 6. The OR gotcha

```bash
kubectl apply -f modules/13-network-policies/07-or-selector.yaml
./modules/13-network-policies/check-connectivity.sh
kubectl -n lab-netpol describe networkpolicy backend-allow-other-frontend-or
```

```
FROM                         dns    :80       :8080
lab-netpol/frontend          ok     ok        blocked
lab-netpol/intruder          ok     blocked   blocked
lab-netpol-other/frontend    ok     ok        blocked
lab-netpol-other/intruder    ok     ok        blocked     <- oops

Spec:
  PodSelector:     app=backend
  Allowing ingress traffic:
    To Port: 80/TCP
    From:
      NamespaceSelector: kubernetes.io/metadata.name=lab-netpol-other
    From:
      PodSelector: app=frontend
  Not affecting egress traffic
  Policy Types: Ingress
```

One extra `-` in the YAML and `describe` shows **two** `From` blocks: now any
pod of `lab-netpol-other` gets in. This mistake is easy to make and hard to
spot in review – always `describe` (or test) your policies.

```bash
kubectl delete -f modules/13-network-policies/07-or-selector.yaml
```

### 7. Default deny egress – and DNS breaks

```bash
kubectl apply -f modules/13-network-policies/08-default-deny-egress.yaml
./modules/13-network-policies/check-connectivity.sh
kubectl -n lab-netpol exec frontend -- curl -sS -m 5 http://backend
```

```
FROM                         dns    :80       :8080
lab-netpol/frontend          FAIL   blocked   blocked
lab-netpol/intruder          FAIL   blocked   blocked
lab-netpol-other/frontend    ok     blocked   blocked
lab-netpol-other/intruder    ok     blocked   blocked

curl: (28) Resolving timed out after 5001 milliseconds
command terminated with exit code 28
```

The pods in `lab-netpol` can't even **resolve** `backend` any more: DNS
queries to CoreDNS are egress traffic too. "Resolving timed out" (rather than
"connection timed out") is the tell-tale sign. This is the #1 surprise with
egress policies.

### 8. Allow DNS

```bash
kubectl apply -f modules/13-network-policies/09-allow-dns-egress.yaml
./modules/13-network-policies/check-connectivity.sh
```

```
FROM                         dns    :80       :8080
lab-netpol/frontend          ok     blocked   blocked
lab-netpol/intruder          ok     blocked   blocked
lab-netpol-other/frontend    ok     blocked   blocked
lab-netpol-other/intruder    ok     blocked   blocked
```

Names resolve again, but `frontend` still can't reach the backend: the server
side (04) allows it, the client side (08) doesn't.

### 9. Allow egress to the backend

```bash
kubectl apply -f modules/13-network-policies/10-allow-egress-to-backend.yaml
./modules/13-network-policies/check-connectivity.sh
kubectl -n lab-netpol exec frontend -- curl -s -m 3 http://backend
```

```
FROM                         dns    :80       :8080
lab-netpol/frontend          ok     ok        blocked
lab-netpol/intruder          ok     blocked   blocked
lab-netpol-other/frontend    ok     blocked   blocked
lab-netpol-other/intruder    ok     blocked   blocked

Name: backend-http
Hostname: backend-645785454c-55sjl
...
```

Now `lab-netpol` is locked down in both directions, with exactly one path
open: frontend → backend:80 (+ DNS for everyone).

### 10. ipBlock: reaching the API server

Pods talk to the API server through the `kubernetes` Service. Where does that
traffic really go?

```bash
kubectl get endpointslices -n default -l kubernetes.io/service-name=kubernetes
kubectl -n lab-netpol exec frontend -- curl -sk -m 3 https://kubernetes.default.svc/version
```

```
NAME         ADDRESSTYPE   PORTS   ENDPOINTS    AGE
kubernetes   IPv4          6443    172.18.0.9   6m1s
command terminated with exit code 7
```

The endpoint is the control-plane **node** (`172.18.0.x:6443`), not a pod –
so no pod selector can match it, and egress is denied. (curl's exit code is 28
– timeout – when packets are dropped, 7 when they're rejected; either way:
blocked.) Allow it with an `ipBlock` on the node network and port **6443**:

```bash
kubectl apply -f modules/13-network-policies/11-ipblock-egress.yaml
kubectl -n lab-netpol exec frontend -- curl -sk -m 3 https://kubernetes.default.svc/version
kubectl -n lab-netpol exec intruder -- curl -sk -m 3 https://kubernetes.default.svc/version
```

```
{
  "major": "1",
  "minor": "37",
  ...
  "gitVersion": "v1.37.0",
  ...
}
command terminated with exit code 7
```

`frontend` reaches the API server (`/version` is readable without
credentials), `intruder` still can't. Note that we had to allow port 6443 on
the node IP, not the Service's `10.96.0.1:443` (Exercise 5).

### 11. Review what's in place

```bash
kubectl -n lab-netpol get networkpolicy
```

```
NAME                                 POD-SELECTOR   AGE
allow-dns-egress                     <none>         14s
backend-allow-frontend               app=backend    45s
default-deny-egress                  <none>         24s
default-deny-ingress                 <none>         50s
frontend-allow-egress-to-apiserver   app=frontend   4s
frontend-allow-egress-to-backend     app=frontend   9s
```

`<none>` = `podSelector: {}` (all pods). This set – default-deny both ways,
DNS allowed, then one small policy per real flow – is the standard
production pattern.

## Exercises

1. **Open the admin port for one pod.** Allow only `lab-netpol/intruder` to
   reach backend's `admin` port (8080) – nothing else changes for anyone.
   Verify with the matrix (`intruder` → `:80 blocked, :8080 ok`).
   *Hint:* with step 7 in place you need two policies (server side and client
   side). Solution: [`solutions/01-admin-port.yaml`](solutions/01-admin-port.yaml).

2. **Both sides matter.** Re-apply `05-allow-from-namespace.yaml`, then lock
   down `lab-netpol-other` with default-deny in **both** directions (one
   policy) plus DNS. Predict the matrix before you run it.
   *Hint:* the backend still allows them – but can they open the connection?
   Solution: [`solutions/02-lock-down-other.yaml`](solutions/02-lock-down-other.yaml)
   (`lab-netpol-other/*` → blocked everywhere). Delete both afterwards.

3. **Select namespaces by your own label.** Label `lab-netpol-other` with
   `team=web` and allow every `team=web` namespace to reach backend:80.
   Who in a real cluster could abuse this, and why is
   `kubernetes.io/metadata.name` safer?
   Solution: [`solutions/03-namespace-label.yaml`](solutions/03-namespace-label.yaml).
   Clean up: `kubectl label namespace lab-netpol-other team-`.

4. **"I allowed the port!"** Apply
   [`exercises/04-service-port.yaml`](exercises/04-service-port.yaml): a new
   Service `backend-admin` on port 9090 and a policy allowing frontend on
   9090. `kubectl -n lab-netpol exec frontend -- curl -s -m 3 http://backend-admin:9090`
   is blocked. Why? Fix the policy.
   *Hint:* which port does the packet have when it arrives at the pod?
   Solution: [`solutions/04-service-port-fixed.yaml`](solutions/04-service-port-fixed.yaml).

5. **The Service IP trap.** Write a policy that allows `intruder` egress to
   `ipBlock: {cidr: 10.96.0.1/32}` on port 443 (the `kubernetes` Service's
   ClusterIP and port), and test `curl -sk https://kubernetes.default.svc/version`
   from `intruder`. Does it work? Explain using step 10.
   *Answer:* it stays blocked (tested): by the time the policy is evaluated
   the destination is the node's IP and port 6443.

## Cleanup

```bash
kubectl delete namespace lab-netpol lab-netpol-other
# Only if you created the Calico fallback cluster:
kind delete cluster --name kube-training-calico
kubectl config use-context kind-kube-training
```

NetworkPolicies are namespaced, so deleting the namespaces removes them.

## Further reading

* [Network Policies](https://kubernetes.io/docs/concepts/services-networking/network-policies/)
* [Declare Network Policy](https://kubernetes.io/docs/tasks/administer-cluster/declare-network-policy/)
* [Debugging DNS Resolution](https://kubernetes.io/docs/tasks/administer-cluster/dns-debugging-resolution/)
* [Network Plugins](https://kubernetes.io/docs/concepts/extend-kubernetes/compute-storage-net/network-plugins/)
* [kind – Known issues / networking](https://kind.sigs.k8s.io/docs/user/known-issues/)
* [SIG Network Policy API (cluster-wide admin policies)](https://network-policy-api.sigs.k8s.io/)
* [Calico on kind](https://docs.tigera.io/calico/latest/getting-started/kubernetes/kind)
