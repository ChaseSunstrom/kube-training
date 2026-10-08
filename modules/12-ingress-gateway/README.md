# Module 12 – Ingress & Gateway API

## Goal

Route HTTP(S) traffic from outside the cluster to many Services through one
entry point – by hostname, path and headers, with TLS – first with the
classic **Ingress** API, then with its successor, the **Gateway API**.

## What you'll learn

* Why L7 routing (Ingress/Gateway) instead of one NodePort/LoadBalancer per Service
* What an ingress **controller** is, and how to run one on kind (hostPort on
  the `ingress-ready` node)
* Ingress: host/path rules, `pathType`, `ingressClassName`, TLS Secrets
* Gateway API v1: GatewayClass → Gateway → HTTPRoute, the role split,
  path/header matching, rewrites, traffic splitting with weights,
  cross-namespace routes (`allowedRoutes`, ReferenceGrant)
* Self-signed TLS with `openssl` → `kubectl create secret tls`
* Reading route **status** to debug, and why controllers differ on Ingress

## Concepts

### Why an L7 entry point?

| | NodePort / LoadBalancer Service ([module 04](../04-services/README.md)) | Ingress / Gateway |
|---|---|---|
| Layer | L4 (TCP/UDP): IP + port | L7 (HTTP): host, path, headers |
| Entry points | one per Service (one cloud load balancer each = $$$) | one shared entry point for many Services |
| TLS | each app terminates TLS itself | terminated centrally, certificates in Secrets |
| Routing features | none | host/path routing, redirects, rewrites, header matching, traffic splitting |

### Controllers do the work

Ingresses, Gateways and HTTPRoutes are **just data** in the API. A
**controller** watches them and configures a reverse proxy. Kubernetes ships
**no** controller; you install one. Without one, an Ingress is accepted and
then simply ignored.

This module uses **Traefik Proxy v3.7** because it is actively maintained,
implements **both** the Ingress API and the Gateway API (it passes the Gateway
API conformance tests), is a single small container image, and runs fine on
kind with a few lines of YAML (01-traefik.yaml – no Helm needed).

> **History: ingress-nginx.** For years the community
> [`kubernetes/ingress-nginx`](https://github.com/kubernetes/ingress-nginx)
> controller was the default choice in tutorials. Its retirement was announced
> in late 2025; best-effort maintenance ended in **March 2026**, and there are
> no further releases or security fixes. Existing installations keep running,
> but you shouldn't start new ones – migrate to another Ingress controller or,
> better, to the Gateway API (the
> [`ingress2gateway`](https://github.com/kubernetes-sigs/ingress2gateway) tool
> converts manifests). Not to be confused with F5's separately maintained
> "NGINX Ingress Controller". The **Ingress API itself** is still GA and
> supported, but feature-frozen: new capabilities only go into the Gateway API.

### How traffic reaches the controller on kind

```
your laptop                          kind "node" containers
curl http://whoami.localhost:80 ──► kube-training-control-plane:80     (extraPortMappings in
                                        │ hostPort 80                    cluster/kind-multi-node.yaml)
                                        ▼
                                    Traefik pod :8000  (nodeSelector ingress-ready=true,
                                        │              toleration for the control-plane taint)
                                        │ Host: whoami.localhost → Service whoami
                                        ▼
                                    whoami pod IPs (from the Service's EndpointSlices)
```

`*.localhost` names resolve to 127.0.0.1 in curl and in modern browsers, so
no `/etc/hosts` edits are needed. (If your tool doesn't resolve them, use
`curl --resolve whoami.localhost:80:127.0.0.1 ...` or add hosts entries.)

Other ways to expose a controller on kind: a NodePort Service plus an
`extraPortMappings` entry for that node port, or a LoadBalancer Service with
[cloud-provider-kind](https://github.com/kubernetes-sigs/cloud-provider-kind)
(useful for Gateway implementations such as Envoy Gateway that create a
LoadBalancer Service per Gateway).

### The Ingress API in one picture

```yaml
spec:
  ingressClassName: lab-traefik      # which controller
  tls:                               # optional: which hosts use which certificate Secret
    - hosts: [whoami.localhost]
      secretName: lab-tls
  rules:
    - host: echo.localhost           # matched against the Host header (wildcards like *.example.com allowed)
      http:
        paths:
          - path: /v1
            pathType: Prefix         # Prefix | Exact | ImplementationSpecific
            backend:
              service: {name: echo-v1, port: {number: 80}}
```

`Prefix` matches whole path **elements** (`/v1` matches `/v1`, `/v1/`,
`/v1/x`, not `/v1beta`); `Exact` matches exactly. When several paths match,
the spec says the **longest** wins, and `Exact` beats `Prefix`. Everything
beyond that – rewrites, redirects, header matching, canaries, timeouts – was
never standardized, so every controller invented its own annotations
(`traefik.ingress.kubernetes.io/...`, `nginx.ingress.kubernetes.io/...`),
which makes Ingress manifests non-portable. As you'll see, controllers even
differ on the standard parts.

### Gateway API: roles and resources

```
 Infrastructure provider       Cluster operator                 Application developers
 ─────────────────────────     ───────────────────────────      ─────────────────────────────
 GatewayClass (cluster)   ◄──  Gateway (namespace A)       ◄──  HTTPRoute (namespace A, B, ...)
 "Traefik implements          listeners: ports, protocols,      hostnames, path/header/query
  class lab-traefik"           hostnames, TLS certs,             matches, filters (rewrite,
                               allowedRoutes (which              redirect, headers), backendRefs
                               namespaces may attach)            with weights
                                                                 ReferenceGrant: permission to
                                                                 point at another namespace
```

* **GA and versioned:** `gateway.networking.k8s.io/v1` (GatewayClass, Gateway,
  HTTPRoute, GRPCRoute, ReferenceGrant…). The API ships as CRDs, installed
  separately from Kubernetes, in a *standard* and an *experimental* channel.
  This module uses the standard channel of **v1.6.2**, a patch release of
  the Gateway API v1.6 that Traefik v3.7 implements.
* **Expressive and portable:** header/query matching, rewrites, redirects,
  header modification and weighted backends are part of the spec, with
  precise precedence rules and conformance tests.
* **Status everywhere:** every object reports in `status.conditions` whether
  it was accepted and why not – your first debugging tool.

### Gateway API vs Ingress cheat sheet

| Ingress | Gateway API |
|---|---|
| `IngressClass` | `GatewayClass` |
| (implicit, part of the controller install) | `Gateway` with explicit listeners |
| `Ingress` rules | `HTTPRoute` (+ `GRPCRoute`, `TLSRoute`, `TCPRoute`…) |
| `spec.tls[].secretName` | `listeners[].tls.certificateRefs` on the Gateway |
| annotations for rewrites, canaries, headers | `filters`, `matches[].headers`, `backendRefs[].weight` |
| same-namespace backends only | cross-namespace with `ReferenceGrant` |

## Files

| File | What it demonstrates |
|---|---|
| [`00-namespace.yaml`](00-namespace.yaml) | The `lab-ingress` namespace |
| [`01-traefik.yaml`](01-traefik.yaml) | Traefik v3.7.13 controller: RBAC, IngressClass `lab-traefik`, Deployment with hostPorts 80/443 |
| [`02-backends.yaml`](02-backends.yaml) | `whoami`, `echo-v1`, `echo-v2` Deployments + Services |
| [`03-ingress.yaml`](03-ingress.yaml) | Ingress host + path rules (`Prefix`, `Exact`) |
| [`04-ingress-tls.yaml`](04-ingress-tls.yaml) | Ingress with TLS (Secret `lab-tls`) |
| [`05-gatewayclass.yaml`](05-gatewayclass.yaml) | GatewayClass `lab-traefik` |
| [`06-gateway.yaml`](06-gateway.yaml) | Gateway with HTTP + HTTPS listeners for `*.gw.localhost` |
| [`07-httproute.yaml`](07-httproute.yaml) | Basic HTTPRoute on both listeners |
| [`08-httproute-matching.yaml`](08-httproute-matching.yaml) | Path + header matching, URL rewrite, header modifier |
| [`09-httproute-split.yaml`](09-httproute-split.yaml) | 90/10 traffic split |
| [`exercises/`](exercises/) / [`solutions/`](solutions/) | Exercises and reference answers |

Cluster-scoped objects created by this module (see *Cleanup*): the Gateway
API CRDs (+ their `safe-upgrades` ValidatingAdmissionPolicy), ClusterRole and
ClusterRoleBinding `lab-ingress-traefik`, IngressClass and GatewayClass
`lab-traefik`.

## Lab

You need the training cluster from `cluster/kind-multi-node.yaml` (it maps
ports 80 and 443 to your laptop – nothing else on your machine may use them).
Run everything from the repo root.

### 1. Install the Gateway API CRDs

```bash
kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.2/standard-install.yaml
kubectl get crd -o name | grep gateway
```

```
customresourcedefinition.apiextensions.k8s.io/backendtlspolicies.gateway.networking.k8s.io serverside-applied
customresourcedefinition.apiextensions.k8s.io/gatewayclasses.gateway.networking.k8s.io serverside-applied
customresourcedefinition.apiextensions.k8s.io/gateways.gateway.networking.k8s.io serverside-applied
customresourcedefinition.apiextensions.k8s.io/grpcroutes.gateway.networking.k8s.io serverside-applied
customresourcedefinition.apiextensions.k8s.io/httproutes.gateway.networking.k8s.io serverside-applied
customresourcedefinition.apiextensions.k8s.io/listenersets.gateway.networking.k8s.io serverside-applied
customresourcedefinition.apiextensions.k8s.io/referencegrants.gateway.networking.k8s.io serverside-applied
customresourcedefinition.apiextensions.k8s.io/tcproutes.gateway.networking.k8s.io serverside-applied
customresourcedefinition.apiextensions.k8s.io/tlsroutes.gateway.networking.k8s.io serverside-applied
customresourcedefinition.apiextensions.k8s.io/udproutes.gateway.networking.k8s.io serverside-applied
validatingadmissionpolicy.admissionregistration.k8s.io/safe-upgrades.gateway.networking.k8s.io serverside-applied
validatingadmissionpolicybinding.admissionregistration.k8s.io/safe-upgrades.gateway.networking.k8s.io serverside-applied
```

`--server-side` because some of these CRDs are too large for the
`last-applied-configuration` annotation of client-side apply. The
ValidatingAdmissionPolicy protects against accidentally installing older CRDs
over newer ones. Traefik must be installed **after** the CRDs – its Gateway
provider needs them to start.

### 2. Install the controller

```bash
kubectl apply -f modules/12-ingress-gateway/00-namespace.yaml -f modules/12-ingress-gateway/01-traefik.yaml
kubectl -n lab-ingress rollout status deployment traefik
kubectl -n lab-ingress get pods -o wide
kubectl get ingressclass
curl -i http://localhost/
```

```
NAME                      READY   STATUS    RESTARTS   AGE   IP           NODE                          ...
traefik-68b8f745b-m9pcf   1/1     Running   0          4s    10.244.0.7   kube-training-control-plane   ...

NAME          CONTROLLER                      PARAMETERS   AGE
lab-traefik   traefik.io/ingress-controller   <none>       4s

HTTP/1.1 404 Not Found
Content-Type: text/plain; charset=utf-8
X-Content-Type-Options: nosniff
Date: Thu, 08 Oct 2026 11:28:02 GMT
Content-Length: 19

404 page not found
```

Traefik runs on the control-plane node (the only one with the port mappings)
and answers on `localhost:80` – with a 404, because no route exists yet. Read
`01-traefik.yaml`: the `args` are Traefik's whole configuration.

> **Why `replicas: 1` and `strategy: Recreate`?** Only one pod per node can
> bind host port 80. A rolling update would start the new pod before stopping
> the old one and get stuck Pending. Real clusters run the controller behind a
> LoadBalancer Service instead of hostPorts, with several replicas.

### 3. Backends

```bash
kubectl apply -f modules/12-ingress-gateway/02-backends.yaml
kubectl -n lab-ingress get deploy,svc
```

```
NAME                      READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/echo-v1   1/1     1            1           3s
deployment.apps/echo-v2   1/1     1            1           3s
deployment.apps/traefik   1/1     1            1           7s
deployment.apps/whoami    2/2     2            2           3s

NAME              TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)   AGE
service/echo-v1   ClusterIP   10.96.128.111   <none>        80/TCP    3s
service/echo-v2   ClusterIP   10.96.111.185   <none>        80/TCP    3s
service/whoami    ClusterIP   10.96.26.217    <none>        80/TCP    3s
```

Plain ClusterIP Services – no NodePort needed.

### 4. Ingress: hosts and paths

```bash
kubectl apply -f modules/12-ingress-gateway/03-ingress.yaml
kubectl -n lab-ingress get ingress
curl http://whoami.localhost/hello
```

```
NAME   CLASS         HOSTS                             ADDRESS     PORTS   AGE
demo   lab-traefik   whoami.localhost,echo.localhost   localhost   80      4s

Hostname: whoami-64b87f796-wpjb2
IP: 127.0.0.1
IP: 10.244.1.14
RemoteAddr: 10.244.0.7:54508
GET /hello HTTP/1.1
Host: whoami.localhost
User-Agent: curl/8.5.0
Accept: */*
Accept-Encoding: gzip
X-Forwarded-For: 172.18.0.1
X-Forwarded-Host: whoami.localhost
X-Forwarded-Port: 80
X-Forwarded-Proto: http
X-Forwarded-Server: traefik-68b8f745b-m9pcf
X-Real-Ip: 172.18.0.1
```

whoami shows what arrived: the original Host and path, `RemoteAddr` = the
Traefik pod (it proxies), and the `X-Forwarded-*` headers that tell the app
who the real client was (`172.18.0.1` is the Docker network's gateway, i.e.
your laptop). Now the path rules – try each URL:

```bash
for p in /v1 /v1/ /v1/orders /v1beta /v2 /v2/ /; do
  printf '%-11s %s\n' "$p" "$(curl -s http://echo.localhost$p)"
done
curl http://nothing.localhost/
```

```
/v1         echo v1
/v1/        echo v1
/v1/orders  echo v1
/v1beta     404 page not found
/v2         echo v2
/v2/        404 page not found
/           404 page not found
404 page not found
```

`Prefix /v1` matches path elements (not `/v1beta`); `Exact /v2` only `/v2`;
unknown hosts and paths get Traefik's 404. Note the flag
`--providers.kubernetesingress.strictPrefixMatching=true` in 01: without it,
Traefik matches prefixes character by character and `/v1beta` would reach
echo-v1 – a reminder that Ingress controllers interpret even the standard
fields differently (Exercise 1 shows another case).

### 5. TLS with a self-signed certificate

Create a certificate for `whoami.localhost` and all `*.gw.localhost` names
(used later by the Gateway) – in `/tmp`, so no key ends up in your repo – and
store it as a TLS Secret:

```bash
openssl req -x509 -newkey rsa:2048 -nodes -days 30 \
  -keyout /tmp/lab-tls.key -out /tmp/lab-tls.crt \
  -subj "/CN=whoami.localhost" \
  -addext "subjectAltName=DNS:whoami.localhost,DNS:*.gw.localhost"
openssl x509 -in /tmp/lab-tls.crt -noout -subject -ext subjectAltName

kubectl -n lab-ingress create secret tls lab-tls --cert=/tmp/lab-tls.crt --key=/tmp/lab-tls.key
kubectl -n lab-ingress get secret lab-tls
```

```
subject=CN = whoami.localhost
X509v3 Subject Alternative Name:
    DNS:whoami.localhost, DNS:*.gw.localhost
secret/lab-tls created
NAME      TYPE                DATA   AGE
lab-tls   kubernetes.io/tls   2      0s
```

(Clients check the **subjectAltName**, not the CN. A `kubernetes.io/tls`
Secret always has the keys `tls.crt` and `tls.key` – see
[module 05](../05-config-secrets/README.md).) Now the TLS Ingress:

```bash
kubectl apply -f modules/12-ingress-gateway/04-ingress-tls.yaml
kubectl -n lab-ingress get ingress
curl --cacert /tmp/lab-tls.crt https://whoami.localhost/
curl https://whoami.localhost/
```

```
NAME         CLASS         HOSTS                             ADDRESS     PORTS     AGE
demo         lab-traefik   whoami.localhost,echo.localhost   localhost   80        8s
whoami-tls   lab-traefik   whoami.localhost                  localhost   80, 443   4s

Hostname: whoami-64b87f796-wpjb2
...
GET / HTTP/1.1
Host: whoami.localhost
...
X-Forwarded-Port: 443
X-Forwarded-Proto: https
...
curl: (60) SSL certificate problem: self-signed certificate
More details here: https://curl.se/docs/sslcerts.html
```

With `--cacert` curl trusts our certificate and the request works; Traefik
terminated TLS and forwarded plain HTTP to the pod (see
`X-Forwarded-Proto: https`). Without it, curl correctly refuses a certificate
signed by nobody it knows (`curl -k` would skip the check – fine for a quick
test, never in scripts). For real certificates use
[cert-manager](https://cert-manager.io/) with Let's Encrypt or your company CA.

### 6. Look inside the controller (optional)

Traefik's dashboard and API show what it built from your objects:

```bash
kubectl -n lab-ingress port-forward deployment/traefik 8080:8080
# browser: http://localhost:8080/dashboard/      or in another terminal:
curl -s localhost:8080/api/http/routers | jq -r '.[] | select(.provider=="kubernetes") | "\(.priority)\t\(.entryPoints|join(","))\t\(.rule)"'
```

```
61	web,websecure	Host("echo.localhost") && (Path("/v1") || PathPrefix("/v1/"))
37	web,websecure	Host("echo.localhost") && Path("/v2")
43	web,websecure	Host("whoami.localhost") && PathPrefix("/")
43	websecure	Host("whoami.localhost") && PathPrefix("/")
```

One router per Ingress path. Note the strict-prefix rule for `/v1`, the
TLS router only on `websecure`, and the **priority** column – it's simply the
length of the rule. Keep the port-forward running for step 10.

### 7. Gateway API: GatewayClass and Gateway

```bash
kubectl apply -f modules/12-ingress-gateway/05-gatewayclass.yaml -f modules/12-ingress-gateway/06-gateway.yaml
kubectl -n lab-ingress wait --for=condition=Programmed gateway/lab-gateway
kubectl get gatewayclass
kubectl -n lab-ingress get gateway
kubectl -n lab-ingress describe gateway lab-gateway | sed -n '/^Status:/,$p'
```

```
NAME          CONTROLLER                      ACCEPTED   AGE
lab-traefik   traefik.io/gateway-controller   True       0s

NAME          CLASS         ADDRESS     PROGRAMMED   AGE
lab-gateway   lab-traefik   localhost   True         0s

Status:
  Addresses:
    Type:   Hostname
    Value:  localhost
  Conditions:
    Message:               Gateway successfully scheduled
    Reason:                Accepted
    Status:                True
    Type:                  Accepted
    Message:               Gateway successfully programmed
    Reason:                Programmed
    Status:                True
    Type:                  Programmed
  Listeners:
    Attached Routes:  0
    Conditions:
      ...
    Name:                    http
    Supported Kinds:
      Kind:           HTTPRoute
      Kind:           GRPCRoute
    ...
```

`ACCEPTED True` on the class means Traefik recognised its `controllerName`;
`PROGRAMMED True` means the listeners are live. Each listener reports its own
conditions and how many routes are attached.

### 8. A first HTTPRoute

```bash
kubectl apply -f modules/12-ingress-gateway/07-httproute.yaml
kubectl -n lab-ingress get httproute
kubectl -n lab-ingress get httproute whoami \
  -o jsonpath='{range .status.parents[*]}{.parentRef.name}{": "}{range .conditions[*]}{.type}={.status} {end}{"\n"}{end}'
curl http://whoami.gw.localhost/
curl --cacert /tmp/lab-tls.crt https://whoami.gw.localhost/
```

```
NAME     HOSTNAMES                 AGE
whoami   ["whoami.gw.localhost"]   4s

lab-gateway: Accepted=True ResolvedRefs=True

Hostname: whoami-64b87f796-wpjb2
...
GET / HTTP/1.1
Host: whoami.gw.localhost
...
Hostname: whoami-64b87f796-g6q5w
...
```

`Accepted` = the Gateway took the route; `ResolvedRefs` = all backends exist.
Because `parentRefs` has no `sectionName`, the route attached to both
listeners – HTTP and HTTPS work, with the certificate configured once on the
Gateway.

### 9. Matching, rewrites and headers

```bash
kubectl apply -f modules/12-ingress-gateway/08-httproute-matching.yaml
curl http://echo.gw.localhost/v1
curl -H "X-Canary: true" http://echo.gw.localhost/v1/orders
curl http://echo.gw.localhost/v1beta
curl -H "X-Canary: true" http://echo.gw.localhost/
curl "http://echo.gw.localhost/api/users?id=7"
```

```
echo v1
echo v2
404 page not found
404 page not found
Hostname: whoami-64b87f796-g6q5w
...
GET /users?id=7 HTTP/1.1
Host: echo.gw.localhost
...
X-Routed-By: lab-gateway
```

* The header-matching rule wins for `/v1/...` because it has the same path
  plus a header match – more specific. (A rule with **only** the header would
  lose to `/v1`: path length is compared first – read the comments in 08.)
* `PathPrefix` is element-wise by spec – `/v1beta` doesn't match, no flag needed.
* `/api/users` arrived at whoami as `/users` (`URLRewrite` with
  `ReplacePrefixMatch`), with the extra header `X-Routed-By`.

### 10. Traffic splitting

```bash
kubectl apply -f modules/12-ingress-gateway/09-httproute-split.yaml
for i in $(seq 1 100); do curl -s http://canary.gw.localhost/; done | sort | uniq -c
```

```
     90 echo v1
     10 echo v2
```

Exactly 90/10 here because Traefik uses weighted round-robin; other
implementations pick randomly, so expect roughly 90/10. To continue a canary
rollout you'd edit the weights (Exercise 3). With the port-forward from step
6 still running, compare how Traefik translated the routes:

```bash
curl -s localhost:8080/api/http/routers | jq -r '.[] | select(.provider=="kubernetesgateway") | "\(.priority)\t\(.entryPoints|join(","))\t\(.rule)"'
```

```
21	web	Host("canary.gw.localhost") && PathPrefix("/")
10420	web	Host("echo.gw.localhost") && (Path("/v1") || PathPrefix("/v1/")) && Header("X-Canary","true")
10319	web	Host("echo.gw.localhost") && (Path("/v1") || PathPrefix("/v1/"))
10418	web	Host("echo.gw.localhost") && (Path("/api") || PathPrefix("/api/"))
21	web	Host("whoami.gw.localhost") && PathPrefix("/")
21	websecure	Host("whoami.gw.localhost") && PathPrefix("/")
```

For Gateway API routes Traefik computes priorities from the spec's precedence
rules (path length, header count…), not from the rule string. Stop the
port-forward with Ctrl-C.

### Installing Traefik with Helm instead (production-style)

In real clusters you'd install the controller from its official Helm chart
([module 18](../18-helm/README.md)) rather than from hand-written YAML. The
equivalent of `01-traefik.yaml` for this kind cluster (into its own
namespace, chart version pinned):

```bash
helm repo add traefik https://traefik.github.io/charts
helm install traefik traefik/traefik --version 41.6.1 \
  --namespace traefik --create-namespace -f - <<'EOF'
nodeSelector: {ingress-ready: "true"}
tolerations:
  - {key: node-role.kubernetes.io/control-plane, operator: Exists, effect: NoSchedule}
ports:
  web: {hostPort: 80}
  websecure: {hostPort: 443}
service: {type: ClusterIP}
providers:
  kubernetesIngress: {enabled: true, strictPrefixMatching: true}
  kubernetesGateway: {enabled: true}
EOF
```

The chart also installs Traefik's own CRDs (IngressRoute, Middleware…) and
by default creates an IngressClass `traefik` (marked as the cluster's
**default** class), a GatewayClass `traefik` and a Gateway `traefik-gateway`
(port 8000) – adjust `ingressClassName` /
`gatewayClassName` / `parentRefs` in the lab files accordingly. Don't run it
next to `01-traefik.yaml`: both want host port 80. (The Gateway API CRDs
from step 1 are still required.)

## Exercises

1. **Catch-all path.** Add `path: /` (Prefix) → `whoami` to the
   `echo.localhost` rule in `03-ingress.yaml` and apply it. Then
   `curl http://echo.localhost/v2`. By the Ingress spec, `Exact /v2` should
   still win. What do you get, and why? (Look at the router priorities from
   step 6.) Make it work without removing the catch-all, then re-apply the
   original 03.
   *Hint:* Traefik annotation `traefik.ingress.kubernetes.io/router.priority`
   applies to all paths of one Ingress.
   Solution: [`solutions/01-ingress-catch-all.yaml`](solutions/01-ingress-catch-all.yaml).

2. **"My route does nothing."** Apply
   [`exercises/02-broken-route.yaml`](exercises/02-broken-route.yaml).
   `curl http://shop.localhost/` gives 404. Using only
   `kubectl -n lab-ingress get httproute shop -o yaml` (`status.parents`),
   find the **two** mistakes and fix them without touching the Gateway.
   Solution: [`solutions/02-fixed-route.yaml`](solutions/02-fixed-route.yaml)
   (`NoMatchingListenerHostname` and `BackendNotFound … service port 8080
   not found`).

3. **Canary rollout.** Move the `canary` route from 90/10 to 50/50 and then
   to 0/100 with `kubectl patch` (JSON patch on
   `/spec/rules/0/backendRefs/0/weight` and `/1/weight`), counting responses
   after each step. What's the advantage over running both versions behind one
   Service with 9 + 1 pods?
   *Hint:* `kubectl -n lab-ingress patch httproute canary --type=json -p '[{"op":"replace","path":"/spec/rules/0/backendRefs/0/weight","value":50},{"op":"replace","path":"/spec/rules/0/backendRefs/1/weight","value":50}]'`.
   *Answer:* weights are independent of pod counts – 1% canary traffic
   doesn't need 100 pods. Re-apply 09 when done.

4. **Share the Gateway with another team.** Create namespace
   `lab-ingress-team` with an app and an HTTPRoute for `team.gw.localhost`
   that attaches to `lab-ingress/lab-gateway`. Read the route's status (it's
   rejected – why?). Then let only **labelled** namespaces attach routes to the
   `http` listener.
   *Hint:* `allowedRoutes.namespaces.from: Selector`; don't lock out
   `lab-ingress` itself.
   Solution: [`solutions/04-team-namespace.yaml`](solutions/04-team-namespace.yaml)
   (status before the fix: `Accepted=False (NotAllowedByListeners)`).

5. **Cross-namespace backend.** In `lab-ingress-team`, create an HTTPRoute for
   `team-whoami.gw.localhost` whose backend is the `whoami` Service in
   **`lab-ingress`**. What do the route status and curl say? Fix it **from
   the `lab-ingress` side**.
   Solution: [`solutions/05-referencegrant.yaml`](solutions/05-referencegrant.yaml)
   (before: `ResolvedRefs=False (RefNotPermitted) … missing ReferenceGrant`,
   curl gets HTTP 500).

6. **Force HTTPS.** Make `http://whoami.gw.localhost/...` answer with a 301
   redirect to the same URL on https, while https keeps serving whoami.
   Check with `curl -i` and `curl -L --cacert /tmp/lab-tls.crt`.
   *Hint:* two routes, one per listener (`sectionName`), and a
   `RequestRedirect` filter.
   Solution: [`solutions/06-https-redirect.yaml`](solutions/06-https-redirect.yaml)
   (re-apply 07 and delete `whoami-redirect` afterwards).

## Cleanup

```bash
kubectl delete namespace lab-ingress lab-ingress-team --ignore-not-found
kubectl delete clusterrolebinding lab-ingress-traefik
kubectl delete clusterrole lab-ingress-traefik
kubectl delete ingressclass lab-traefik
kubectl delete gatewayclass lab-traefik
# The Gateway API CRDs - only if nothing else in your cluster uses them
# (later modules may install them again):
kubectl delete -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.2/standard-install.yaml
rm -f /tmp/lab-tls.crt /tmp/lab-tls.key
```

Delete the namespaces **before** the CRDs; deleting a CRD deletes all
objects of that kind everywhere.

## Further reading

* [Ingress](https://kubernetes.io/docs/concepts/services-networking/ingress/) and [Ingress Controllers](https://kubernetes.io/docs/concepts/services-networking/ingress-controllers/)
* [Gateway API (kubernetes.io)](https://kubernetes.io/docs/concepts/services-networking/gateway/) and [gateway-api.sigs.k8s.io](https://gateway-api.sigs.k8s.io/) – guides, HTTPRoute reference, implementations & conformance
* [Migrating from Ingress](https://gateway-api.sigs.k8s.io/guides/migrating-from-ingress/) and [ingress2gateway](https://github.com/kubernetes-sigs/ingress2gateway)
* [kubernetes/ingress-nginx](https://github.com/kubernetes/ingress-nginx) – retirement notice and migration pointers
* [kind: Ingress](https://kind.sigs.k8s.io/docs/user/ingress/) and [LoadBalancer](https://kind.sigs.k8s.io/docs/user/loadbalancer/)
* [Traefik: Kubernetes Gateway API provider](https://doc.traefik.io/traefik/reference/install-configuration/providers/kubernetes/kubernetes-gateway/) and [Kubernetes Ingress provider](https://doc.traefik.io/traefik/reference/install-configuration/providers/kubernetes/kubernetes-ingress/)
* [TLS Secrets](https://kubernetes.io/docs/concepts/configuration/secret/#tls-secrets)
