# 04 – Services

## Goal

Give a changing set of pods one stable name and address, understand exactly
how traffic reaches a pod through each Service type, and be able to debug a
Service that "doesn't work".

## What you'll learn

* Why Services exist, and how selectors, EndpointSlices, kube-proxy and CoreDNS fit together
* `ClusterIP`, `NodePort`, headless, `ExternalName` and `LoadBalancer` Services
* Services **without** a selector, backed by a hand-written EndpointSlice
* DNS names (`<svc>.<ns>.svc.cluster.local`), `resolv.conf` search domains and `ndots:5`
* How readiness decides which pods are in an EndpointSlice
* `kubectl port-forward`, `sessionAffinity`, named `targetPort`s
* `internalTrafficPolicy` and `externalTrafficPolicy` (and the client-IP trade-off)
* Why a `LoadBalancer` stays `<pending>` on kind, and what fixes it

## Concepts

### The problem

Pods come and go (rollouts, rescheduling, scaling) and each one gets a new
IP. Clients need something that does not change. A **Service** is a stable
virtual IP + DNS name + port, in front of "all ready pods matching this
selector, right now".

### The moving parts

```
                 ┌──────────── Service whoami (selector app=whoami, port 80 → targetPort http)
                 │                     │
 EndpointSlice controller  watches pods matching the selector, writes
                 │          EndpointSlices: [10.244.1.58:80 ready, 10.244.3.65:80 ready, ...]
                 ▼
 kube-proxy (every node)   watches Services + EndpointSlices, programs iptables/nftables/IPVS:
                           "packets to 10.96.232.18:80 → DNAT to one ready endpoint, at random"
 CoreDNS                   watches Services + EndpointSlices, answers
                           whoami.lab-services.svc.cluster.local → 10.96.232.18
```

There is no process listening on a ClusterIP – the address exists only in
the forwarding rules on every node, which is why you cannot `ping` it.
The load balancing is per **connection** (not per request), random, and
without health checks of its own: it relies on the pods' readiness probes.

### Service types

| Type | Reachable from | How |
|---|---|---|
| `ClusterIP` (default) | inside the cluster | virtual IP, kube-proxy rules on every node |
| `NodePort` | outside, via `<any node IP>:<30000-32767>` | ClusterIP **plus** a port opened on every node |
| `LoadBalancer` | outside, via an external IP | NodePort **plus** an external load balancer created by a cloud controller |
| headless (`clusterIP: None`) | inside | no virtual IP; DNS returns the ready pod IPs directly |
| `ExternalName` | inside | DNS CNAME to another hostname; no proxying at all |

### DNS

Every Service gets `<service>.<namespace>.svc.cluster.local`. Pods get this
`/etc/resolv.conf` (namespace `lab-services`):

```
search lab-services.svc.cluster.local svc.cluster.local cluster.local
nameserver 10.96.0.10        # the kube-dns Service (CoreDNS)
options ndots:5
```

So from a pod in `lab-services`: `whoami` works (first search domain),
`whoami.lab-services` works (second), `kube-dns.kube-system` works (another
namespace), and the FQDN always works. `ndots:5` means "a name with fewer
than 5 dots is tried with each search domain first" – so `api.example.com`
causes up to three failed cluster lookups before the real one. Write a
trailing dot (`api.example.com.`) to skip the search list in hot paths.

### Traffic policies

| Field | Applies to | `Cluster` (default) | `Local` |
|---|---|---|---|
| `internalTrafficPolicy` | pod → ClusterIP | any ready pod, any node | only pods on the **client's** node; none there → connection fails |
| `externalTrafficPolicy` | NodePort / LoadBalancer traffic from outside | any node forwards to any pod; source IP is **SNATed** to the node's IP | a node only forwards to its **own** pods; the **client IP is preserved**; nodes without a ready pod drop the traffic (cloud LBs health-check `healthCheckNodePort` to avoid them) |

## Files

| File | What it demonstrates |
|---|---|
| [`00-namespace.yaml`](00-namespace.yaml) | The `lab-services` namespace |
| [`01-whoami-deployment.yaml`](01-whoami-deployment.yaml) | 3 whoami pods with a **named** container port and a readiness probe |
| [`02-client.yaml`](02-client.yaml) | A netshoot pod for curl/dig from inside the cluster |
| [`03-clusterip.yaml`](03-clusterip.yaml) | ClusterIP Service `whoami`, `targetPort: http` |
| [`04-nodeport.yaml`](04-nodeport.yaml) | NodePort 30080 (mapped to `localhost:30080` by the kind config), `externalTrafficPolicy` |
| [`05-headless.yaml`](05-headless.yaml) | Headless Service: DNS returns pod IPs, SRV records |
| [`06-externalname.yaml`](06-externalname.yaml) | ExternalName: a DNS CNAME |
| [`07-service-without-selector.yaml`](07-service-without-selector.yaml) | A Service with no selector |
| [`08-endpointslice.yaml`](08-endpointslice.yaml) | A manual EndpointSlice for it |
| [`09-session-affinity.yaml`](09-session-affinity.yaml) | `sessionAffinity: ClientIP` |
| [`10-internal-traffic-policy.yaml`](10-internal-traffic-policy.yaml) | `internalTrafficPolicy: Local` |
| [`11-loadbalancer.yaml`](11-loadbalancer.yaml) | `type: LoadBalancer` – `<pending>` on kind |
| [`exercises/`](exercises/), [`solutions/`](solutions/) | Exercise starting points and reference answers |

## Lab

### 1. Backends, a client and a ClusterIP Service

```bash
kubectl apply -f modules/04-services/00-namespace.yaml
kubectl apply -f modules/04-services/01-whoami-deployment.yaml -f modules/04-services/02-client.yaml
kubectl apply -f modules/04-services/03-clusterip.yaml
kubectl get pods -n lab-services -o wide
kubectl get service whoami -n lab-services
kubectl get endpointslices -n lab-services -l kubernetes.io/service-name=whoami
```

```
NAME                      READY   STATUS    RESTARTS   AGE   IP             NODE
client                    1/1     Running   0          3s    10.244.3.193   kube-training-worker
whoami-645cdd46c4-4pn5t   1/1     Running   0          3s    10.244.3.194   kube-training-worker
whoami-645cdd46c4-8bvxx   1/1     Running   0          3s    10.244.3.195   kube-training-worker
whoami-645cdd46c4-xpk62   1/1     Running   0          3s    10.244.1.225   kube-training-worker2

NAME     TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)   AGE
whoami   ClusterIP   10.96.232.18   <none>        80/TCP    3s

NAME           ADDRESSTYPE   PORTS   ENDPOINTS                                AGE
whoami-tjvft   IPv4          80      10.244.1.225,10.244.3.194,10.244.3.195   3s
```

The EndpointSlice (named after the Service plus a random suffix) holds the
pod IPs, and its port is **80** although the Service says `targetPort: http`:
the controller resolved the name against each pod's container ports.

```bash
kubectl exec -n lab-services client -- sh -c 'for i in $(seq 6); do curl -s http://whoami | grep Hostname; done'
```

```
Hostname: whoami-645cdd46c4-xpk62
Hostname: whoami-645cdd46c4-8bvxx
Hostname: whoami-645cdd46c4-8bvxx
Hostname: whoami-645cdd46c4-xpk62
Hostname: whoami-645cdd46c4-xpk62
Hostname: whoami-645cdd46c4-xpk62
```

Random per connection – not round robin. A full answer also shows
`RemoteAddr: 10.244.3.193:...` – the client pod's own IP: pod-to-Service
traffic is not source-NATed.

Want to see the "virtual IP"? It is a set of iptables rules on every node
(kube-proxy's default mode on kind):

```bash
docker exec kube-training-worker iptables-save | grep 'lab-services/whoami:http' | grep -v -- '-A KUBE-SEP'
```

```
-A KUBE-SERVICES -d 10.96.232.18/32 -p tcp -m comment --comment "lab-services/whoami:http cluster IP" -m tcp --dport 80 -j KUBE-SVC-VXUIABVVXYGK5ADU
-A KUBE-SVC-VXUIABVVXYGK5ADU ! -s 10.244.0.0/16 -d 10.96.232.18/32 -p tcp -m comment --comment "lab-services/whoami:http cluster IP" -m tcp --dport 80 -j KUBE-MARK-MASQ
-A KUBE-SVC-VXUIABVVXYGK5ADU -m comment --comment "lab-services/whoami:http -> 10.244.1.225:80" -m statistic --mode random --probability 0.33333333349 -j KUBE-SEP-44U6PCXYRY2GRUJ7
-A KUBE-SVC-VXUIABVVXYGK5ADU -m comment --comment "lab-services/whoami:http -> 10.244.3.194:80" -m statistic --mode random --probability 0.50000000000 -j KUBE-SEP-TTYSXVB44226FTY5
-A KUBE-SVC-VXUIABVVXYGK5ADU -m comment --comment "lab-services/whoami:http -> 10.244.3.195:80" -j KUBE-SEP-AJEUSGHKM7IA4C7B
```

1/3, then 1/2 of the rest, then the remainder: an even random spread.
(The `KUBE-MARK-MASQ` line SNATs only traffic that does *not* come from a pod.)

### 2. DNS

```bash
kubectl exec -n lab-services client -- cat /etc/resolv.conf
kubectl exec -n lab-services client -- dig +short whoami.lab-services.svc.cluster.local
kubectl exec -n lab-services client -- nslookup whoami                 # uses the search list
kubectl exec -n lab-services client -- dig +short whoami               # dig does NOT, by default
kubectl exec -n lab-services client -- dig +short +search whoami
kubectl exec -n lab-services client -- dig +short kubernetes.default.svc.cluster.local
```

```
search lab-services.svc.cluster.local svc.cluster.local cluster.local
nameserver 10.96.0.10
options ndots:5
10.96.232.18
Server:		10.96.0.10
Address:	10.96.0.10#53

Name:	whoami.lab-services.svc.cluster.local
Address: 10.96.232.18

                       <- empty: dig looked up the literal name "whoami."
10.96.232.18
10.96.0.1
```

If a short name works in your app but not in `dig`, that is why. Two more
record types worth knowing:

```bash
kubectl exec -n lab-services client -- dig +short SRV _http._tcp.whoami.lab-services.svc.cluster.local
kubectl exec -n lab-services client -- dig +short -x 10.96.232.18
```

```
0 100 80 whoami.lab-services.svc.cluster.local.
whoami.lab-services.svc.cluster.local.
```

The SRV record exists because the Service port is **named** (`http`): it lets clients discover the port number.

### 3. NodePort: reach the app from your laptop

```bash
kubectl apply -f modules/04-services/04-nodeport.yaml
kubectl get service whoami-nodeport -n lab-services
for i in $(seq 4); do curl -s http://localhost:30080 | grep -E 'Hostname|RemoteAddr' | tr '\n' ' '; echo; done
```

```
NAME              TYPE       CLUSTER-IP      EXTERNAL-IP   PORT(S)        AGE
whoami-nodeport   NodePort   10.96.200.102   <none>        80:30080/TCP   0s
Hostname: whoami-645cdd46c4-4pn5t RemoteAddr: 172.18.0.4:5770
Hostname: whoami-645cdd46c4-8bvxx RemoteAddr: 172.18.0.4:19804
Hostname: whoami-645cdd46c4-xpk62 RemoteAddr: 172.18.0.4:52302
Hostname: whoami-645cdd46c4-4pn5t RemoteAddr: 172.18.0.4:53142
```

`PORT(S) 80:30080` = Service port 80, node port 30080. Your request went
`localhost:30080` → (kind's port mapping) → the **control-plane** node
`172.18.0.4:30080` → kube-proxy → a pod on a **worker**. The pod saw
`RemoteAddr: 172.18.0.4` – the control-plane node, not your laptop: with
`externalTrafficPolicy: Cluster` the node SNATs traffic it forwards so the
reply comes back through it.

(No `localhost:30080`? You are on the single-node config or another
cluster without that port mapping – use step 7's port-forward, or curl a node
from the kind network as below.)

Every node opened the port. Ask each node directly, from a throw-away
container on kind's docker network (which plays "a machine outside the cluster"):

```bash
for n in kube-training-control-plane kube-training-worker kube-training-worker2; do
  docker run --rm --network kind curlimages/curl:8.11.1 -s -m 3 http://$n:30080 \
    | grep -E 'Hostname|RemoteAddr' | tr '\n' ' '; echo " <- via $n"
done
```

```
Hostname: whoami-645cdd46c4-8bvxx RemoteAddr: 172.18.0.4:53585  <- via kube-training-control-plane
Hostname: whoami-645cdd46c4-8bvxx RemoteAddr: 10.244.3.1:50400  <- via kube-training-worker
Hostname: whoami-645cdd46c4-4pn5t RemoteAddr: 172.18.0.2:48267  <- via kube-training-worker2
```

All three nodes answer, and each one hides the real client IP: the pod
sees the IP of the node that forwarded the request (`172.18.0.4`,
`172.18.0.2`), or – when the node that received it also hosts the chosen
pod – that node's address on the pod network (`10.244.3.1`).

### 4. externalTrafficPolicy: Local

```bash
kubectl patch service whoami-nodeport -n lab-services -p '{"spec":{"externalTrafficPolicy":"Local"}}'
curl -s -m 3 http://localhost:30080; echo "exit code $?"
docker run --rm --network kind curlimages/curl:8.11.1 sh -c \
  'echo "my IP: $(hostname -i)"; for n in kube-training-control-plane kube-training-worker kube-training-worker2; do echo "$n: $(curl -s -m 3 http://$n:30080 | grep RemoteAddr || echo no answer)"; done'
```

```
exit code 28
my IP: 172.18.0.9
kube-training-control-plane: no answer
kube-training-worker: RemoteAddr: 172.18.0.9:57902
kube-training-worker2: RemoteAddr: 172.18.0.9:46908
```

* `localhost:30080` now **times out** (curl exit code 28): it enters through the
  control-plane node, which runs no whoami pod, and `Local` forbids forwarding to other nodes.
* The workers answer, and the pod sees the **real client IP** (`172.18.0.9`, the curl container).

That is the trade-off: `Local` preserves client IPs and saves a hop, but
only nodes with a ready pod can take traffic – cloud load balancers handle
that by health-checking each node. Put it back:

```bash
kubectl patch service whoami-nodeport -n lab-services -p '{"spec":{"externalTrafficPolicy":"Cluster"}}'
```

### 5. Readiness decides who is in the EndpointSlice

Make one pod fail its readiness probe – whoami lets you set the status code
of `/health` with a POST:

```bash
POD=$(kubectl get pods -n lab-services -l app=whoami -o jsonpath='{.items[0].metadata.name}')
IP=$(kubectl get pod $POD -n lab-services -o jsonpath='{.status.podIP}')
kubectl exec -n lab-services client -- curl -s -X POST -d 503 http://$IP/health
kubectl get pods -n lab-services -l app=whoami          # one pod 0/1 after ~2s
kubectl get endpointslices -n lab-services -l kubernetes.io/service-name=whoami \
  -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{"\t"}ready={.conditions.ready}{"\t"}{.targetRef.name}{"\n"}{end}'
kubectl exec -n lab-services client -- sh -c 'for i in $(seq 20); do curl -s http://whoami | grep Hostname; done' | sort | uniq -c
```

```
NAME                      READY   STATUS    RESTARTS   AGE
whoami-645cdd46c4-4pn5t   0/1     Running   0          37s
whoami-645cdd46c4-8bvxx   1/1     Running   0          37s
whoami-645cdd46c4-xpk62   1/1     Running   0          37s

10.244.1.225	ready=true	whoami-645cdd46c4-xpk62
10.244.3.194	ready=false	whoami-645cdd46c4-4pn5t
10.244.3.195	ready=true	whoami-645cdd46c4-8bvxx

     12 Hostname: whoami-645cdd46c4-8bvxx
      8 Hostname: whoami-645cdd46c4-xpk62
```

The unready pod stays **in** the EndpointSlice, but with `ready: false`
(and `serving: false`); kube-proxy and CoreDNS only use ready endpoints, so it
gets no traffic and the headless name no longer returns its IP. The pod was
not restarted – this is readiness, not liveness (module 01). Note that the
`ENDPOINTS` column of `kubectl get endpointslices` lists *all* addresses,
ready or not; use `-o yaml` or `kubectl describe service` (its `Endpoints:` line shows only ready ones).

During a rolling update the same mechanism, plus the `terminating`
condition, moves traffic from old pods to new ones.

Make it healthy again:

```bash
kubectl exec -n lab-services client -- curl -s -X POST -d 200 http://$IP/health
```

The older `Endpoints` API still exists, but is deprecated:

```bash
kubectl get endpoints whoami -n lab-services
```

```
Warning: v1 Endpoints is deprecated in v1.33+; use discovery.k8s.io/v1 EndpointSlice
NAME     ENDPOINTS                                         AGE
whoami   10.244.1.225:80,10.244.3.194:80,10.244.3.195:80   47s
```

### 6. Headless Services and ExternalName

```bash
kubectl apply -f modules/04-services/05-headless.yaml -f modules/04-services/06-externalname.yaml
kubectl get services -n lab-services whoami-headless whoami-alias
kubectl exec -n lab-services client -- dig +short whoami-headless.lab-services.svc.cluster.local
kubectl exec -n lab-services client -- dig +short SRV _http._tcp.whoami-headless.lab-services.svc.cluster.local
```

```
NAME              TYPE           CLUSTER-IP   EXTERNAL-IP                             PORT(S)   AGE
whoami-headless   ClusterIP      None         <none>                                  80/TCP    0s
whoami-alias      ExternalName   <none>       whoami.lab-services.svc.cluster.local   <none>    0s
10.244.1.225
10.244.3.195
10.244.3.194
0 33 80 10-244-3-195.whoami-headless.lab-services.svc.cluster.local.
0 33 80 10-244-3-194.whoami-headless.lab-services.svc.cluster.local.
0 33 80 10-244-1-225.whoami-headless.lab-services.svc.cluster.local.
```

No virtual IP: DNS hands out the three pod IPs, and the client chooses
(most resolvers just take the first). Each pod also gets a name under the
headless Service. With a StatefulSet those names become stable
(`db-0.db.ns.svc.cluster.local` – module 07).

The ExternalName Service is pure DNS:

```bash
kubectl exec -n lab-services client -- dig whoami-alias.lab-services.svc.cluster.local | sed -n '/ANSWER SECTION/,/^$/p'
kubectl exec -n lab-services client -- curl -s http://whoami-alias | grep -E 'Hostname|Host:'
```

```
;; ANSWER SECTION:
whoami-alias.lab-services.svc.cluster.local. 30	IN CNAME whoami.lab-services.svc.cluster.local.
whoami.lab-services.svc.cluster.local. 30 IN A	10.96.232.18

Hostname: whoami-645cdd46c4-8bvxx
Host: whoami-alias
```

It works, but look at `Host: whoami-alias`: the client still sends the
*alias* name. A real external HTTPS service would see the wrong Host header
and a TLS SNI that does not match its certificate – the classic
ExternalName gotcha.

### 7. `kubectl port-forward`

```bash
kubectl port-forward svc/whoami 8080:80 -n lab-services       # leave running
# in another terminal:
for i in $(seq 5); do curl -s localhost:8080 | grep Hostname; done
```

```
Forwarding from 127.0.0.1:8080 -> 80
Hostname: whoami-645cdd46c4-8bvxx
Hostname: whoami-645cdd46c4-8bvxx
Hostname: whoami-645cdd46c4-8bvxx
Hostname: whoami-645cdd46c4-8bvxx
Hostname: whoami-645cdd46c4-8bvxx
```

Always the same pod: `port-forward svc/...` picks **one** pod when it
starts and tunnels to it through the API server and kubelet – it never goes
through kube-proxy and never load-balances. Great for debugging, not a way
to expose an app. (`kubectl port-forward pod/<name>` and `deploy/<name>` work too.)

### 8. A Service without a selector

```bash
kubectl apply -f modules/04-services/07-service-without-selector.yaml
kubectl get endpointslices -n lab-services -l kubernetes.io/service-name=legacy   # No resources found
kubectl apply -f modules/04-services/08-endpointslice.yaml
kubectl describe service legacy -n lab-services | grep -E '^IP:|Endpoints'
kubectl exec -n lab-services client -- curl -s -m 3 http://legacy; echo "exit code $?"
```

```
IP:                       10.96.44.231
Endpoints:                192.0.2.10:80
exit code 7
```

The Service routes to whatever the slice says – here a documentation
address where nothing listens, so the request fails (exit code 7 "couldn't
connect" or 28 "timeout", depending on your network). Now run a real "legacy app" **outside** the
cluster – a plain container on kind's docker network, unknown to Kubernetes
– and point the slice at it:

```bash
docker run -d --rm --name legacy-whoami --network kind \
  -e WHOAMI_NAME="legacy app outside the cluster" traefik/whoami:v1.10
LEGACY_IP=$(docker inspect -f '{{.NetworkSettings.Networks.kind.IPAddress}}' legacy-whoami)
sed "s/192.0.2.10/$LEGACY_IP/" modules/04-services/08-endpointslice.yaml | kubectl apply -f -
kubectl exec -n lab-services client -- curl -s http://legacy | head -2
```

```
endpointslice.discovery.k8s.io/legacy-1 configured
Name: legacy app outside the cluster
Hostname: 5a19fdcef2f7
```

`Hostname` is now a docker container ID, not a pod name. Pods use the stable
name `legacy`; if the legacy app moves, you update one EndpointSlice (or,
once it runs in the cluster, add a selector) and no client changes.
(Podman users: `podman run ... --network kind` and `podman inspect`.)

### 9. Session affinity and internalTrafficPolicy

```bash
kubectl apply -f modules/04-services/09-session-affinity.yaml -f modules/04-services/10-internal-traffic-policy.yaml
kubectl exec -n lab-services client -- sh -c 'for i in $(seq 6); do curl -s http://whoami-sticky | grep Hostname; done'
```

```
Hostname: whoami-645cdd46c4-xpk62
Hostname: whoami-645cdd46c4-xpk62
Hostname: whoami-645cdd46c4-xpk62
Hostname: whoami-645cdd46c4-xpk62
Hostname: whoami-645cdd46c4-xpk62
Hostname: whoami-645cdd46c4-xpk62
```

Same backends as `whoami`, but every connection from the client's IP now
lands on one pod (compare with step 1).

```bash
kubectl get pod client -n lab-services -o wide                   # which node is the client on?
kubectl get pods -n lab-services -l app=whoami -o wide
kubectl exec -n lab-services client -- sh -c 'for i in $(seq 8); do curl -s -m 2 http://whoami-local | grep Hostname || echo FAILED; done' | sort | uniq -c
```

```
      4 Hostname: whoami-645cdd46c4-4pn5t
      4 Hostname: whoami-645cdd46c4-8bvxx
```

Only the two pods on the client's node (`kube-training-worker` in this run)
answer. (If the scheduler happened to put no whoami pod on the client's node,
every request prints `FAILED` – that is exactly the failure mode exercise 3
explores.)

### 10. LoadBalancer on kind

```bash
kubectl apply -f modules/04-services/11-loadbalancer.yaml
kubectl get service whoami-lb -n lab-services
```

```
NAME        TYPE           CLUSTER-IP      EXTERNAL-IP   PORT(S)        AGE
whoami-lb   LoadBalancer   10.96.124.212   <pending>     80:31276/TCP   4s
```

`<pending>` forever, and no event explains why: nothing in a kind cluster
implements load balancers. In a cloud, the **cloud-controller-manager**
sees the Service, creates a cloud load balancer that targets the node ports
(note the random node port 31276 – a LoadBalancer is a NodePort Service
underneath), and writes its address into `status.loadBalancer`. The
ClusterIP and node port work fine in the meantime.

To get real external IPs on kind, run
[cloud-provider-kind](https://github.com/kubernetes-sigs/cloud-provider-kind)
on your machine (download a release binary, or `go install sigs.k8s.io/cloud-provider-kind@latest`,
and leave it running; see kind's [LoadBalancer guide](https://kind.sigs.k8s.io/docs/user/loadbalancer/)).
It watches your kind clusters and, for each LoadBalancer Service, starts a
small proxy container on the kind network and publishes its IP as the
EXTERNAL-IP. On bare-metal clusters the same role is played by MetalLB,
kube-vip or Cilium's LB IPAM. Most real clusters put *one* LoadBalancer in
front of an Ingress or Gateway controller (module 12) rather than one per app.

## Exercises

1. **DNS from another namespace.** Start a throw-away pod in `default`
   (`kubectl run tmp -it --rm --image=nicolaka/netshoot:v0.13 -- bash`) and
   find out which of these resolve, and why: `whoami`, `whoami.lab-services`,
   `whoami.lab-services.svc`, `whoami.lab-services.svc.cluster.local`.
   <details><summary>Answer</summary>

   All except the bare `whoami`: in `default` the first search domain is
   `default.svc.cluster.local`, so `whoami` becomes `whoami.default.svc.cluster.local`,
   which does not exist. `whoami.lab-services` + `svc.cluster.local` works,
   `whoami.lab-services.svc` + `cluster.local` works. Exit with `exit`; `--rm` deletes the pod.
   </details>

2. **Peers that are not ready yet.** Create a second headless Service that
   also returns pods that are *not* ready, make one pod unready (step 5) and
   compare the DNS answers of both headless Services.
   *Hint:* `kubectl explain service.spec.publishNotReadyAddresses`.
   Solution: [`solutions/headless-not-ready.yaml`](solutions/headless-not-ready.yaml).

3. **When Local means nothing.** Run a client pod on the control-plane node
   (which has no whoami pod) and call `whoami-local` and `whoami` from it.
   *Hint:* you need a `nodeSelector` and a toleration for `node-role.kubernetes.io/control-plane`.
   Solution: [`solutions/client-on-control-plane.yaml`](solutions/client-on-control-plane.yaml) –
   `whoami-local` times out (curl exit code 28), `whoami` works.

4. **Change the port, not the Services.** Make whoami listen on port 8080
   (`WHOAMI_PORT_NUMBER`) without editing any Service. Which Services keep
   working and why? What would have broken with `targetPort: 80`?
   Solution: [`solutions/whoami-port-8080.yaml`](solutions/whoami-port-8080.yaml).
   Re-apply `01-whoami-deployment.yaml` afterwards.

5. **Debug a broken Service.** Apply [`exercises/broken-service.yaml`](exercises/broken-service.yaml)
   and make `curl http://shop-frontend` work from the client. There are two bugs.
   *Hint:* empty EndpointSlice → selector; endpoints but "connection refused" → port.
   Solution: [`solutions/fixed-service.yaml`](solutions/fixed-service.yaml).

6. **Under the hood.** For the NodePort Service, find the iptables rules on a
   worker that match port 30080, and explain the `KUBE-MARK-MASQ` rule you
   find there in terms of step 3 and 4.
   *Hint:* `docker exec kube-training-worker iptables-save | grep 30080`, then follow the `KUBE-EXT-...` chain.
   <details><summary>Answer</summary>

   Traffic to `--dport 30080` (chain `KUBE-NODEPORTS`) jumps to a `KUBE-EXT-…`
   chain, which marks the packet for masquerading (SNAT) and continues to the
   same `KUBE-SVC-…` chain as the ClusterIP. The mark is why pods saw a node
   IP as `RemoteAddr`. With `externalTrafficPolicy: Local` the `KUBE-EXT-…`
   chain sends external traffic to a `KUBE-SVL-…` chain that lists only the
   endpoints on *this* node, without the masquerade mark – hence the real
   client IP. On the control-plane node that chain has no endpoints, so the
   traffic is dropped.
   ```
   -A KUBE-EXT-M7T6GYSEJU6E2AQS -j KUBE-SVL-M7T6GYSEJU6E2AQS
   -A KUBE-SVL-M7T6GYSEJU6E2AQS -m comment --comment "lab-services/whoami-nodeport:http -> 10.244.3.231:80" ... -j KUBE-SEP-...
   ```
   </details>

## Cleanup

```bash
kubectl delete namespace lab-services
docker rm -f legacy-whoami        # the "outside" container from step 8, if you started it
```

## Further reading

* [Service](https://kubernetes.io/docs/concepts/services-networking/service/) and [Virtual IPs and service proxies](https://kubernetes.io/docs/reference/networking/virtual-ips/)
* [EndpointSlices](https://kubernetes.io/docs/concepts/services-networking/endpoint-slices/)
* [DNS for Services and Pods](https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/)
* [Service internal traffic policy](https://kubernetes.io/docs/concepts/services-networking/service-traffic-policy/) and [source IP with `externalTrafficPolicy`](https://kubernetes.io/docs/tutorials/services/source-ip/)
* [Debug Services](https://kubernetes.io/docs/tasks/debug/debug-application/debug-service/)
* [kind: LoadBalancer](https://kind.sigs.k8s.io/docs/user/loadbalancer/) and [cloud-provider-kind](https://github.com/kubernetes-sigs/cloud-provider-kind)
* [Use port forwarding to access applications in a cluster](https://kubernetes.io/docs/tasks/access-application-cluster/port-forward-access-application-cluster/)
