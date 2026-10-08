# Module 11 – RBAC

## Goal

Understand **who** is talking to the API server and **what** they are allowed
to do – and grant pods exactly the permissions they need, nothing more.

## What you'll learn

* Authentication vs authorization: users, groups and ServiceAccounts
* ServiceAccounts: the automatic `default` SA, `automountServiceAccountToken`,
  and the projected, short-lived token every pod gets
* `kubectl create token`, bound tokens, and using a token by hand
* Role + RoleBinding (namespaced), ClusterRole + RoleBinding (reuse a
  ClusterRole in one namespace), ClusterRole + ClusterRoleBinding (cluster-wide)
* Aggregated ClusterRoles and the built-in `view` / `edit` / `admin` /
  `cluster-admin`
* `kubectl auth can-i` (with `--as`, `--list`) and `kubectl auth whoami`
* A pod that runs `kubectl` with its own token: Forbidden first, then fixed
* Least privilege – and why "can create pods" is a big permission

## Concepts

### Every request: authentication → authorization → admission

```
kubectl / pod / controller
        │  credentials: client certificate, bearer token (SA token, OIDC id_token), ...
        ▼
┌──────────────────────────────────────────────────────────────────────┐
│ API server                                                           │
│ 1. Authentication  "who are you?"  -> username + groups  (401 if no)  │
│ 2. Authorization   "may <user> <verb> <resource> in <namespace>?"     │
│                    RBAC (+ Node authorizer, webhooks)    (403 if no)  │
│ 3. Admission       mutate/validate the object (quotas, PSA, defaults) │
└──────────────────────────────────────────────────────────────────────┘
```

`Unauthorized` (401) = the API server doesn't know who you are.
`Forbidden` (403) = it knows exactly who you are, and RBAC said no.

### Users vs ServiceAccounts

| | Users (humans, external systems) | ServiceAccounts (processes in pods) |
|---|---|---|
| Kubernetes object? | **No.** There is no `User` kind | Yes, namespaced: `kubectl get sa` |
| Where they come from | Client certificates (CN = user, O = groups), OIDC tokens (Dex, Keycloak, cloud IAM), authentication webhooks | Created by you (plus one `default` per namespace) |
| Credentials | Managed outside Kubernetes | Short-lived JWTs issued by the API server (TokenRequest API) |
| Name in RBAC | `jane` (whatever the authenticator says) | `system:serviceaccount:<ns>:<name>` |
| Groups | From the cert / OIDC claims | `system:serviceaccounts`, `system:serviceaccounts:<ns>` |

Every authenticated identity is also in `system:authenticated`. RBAC matches
user and group **names as strings** – you can bind a user who has never logged
in. Your kind admin user is a client certificate for `kubernetes-admin` in
group `kubeadm:cluster-admins`, which a ClusterRoleBinding maps to
`cluster-admin` (lab step 1).

### ServiceAccount tokens

Pods get **bound, projected tokens** (the default since Kubernetes 1.22), and
since 1.24 the old long-lived token Secrets are no longer created
automatically; leftover auto-generated ones that sit unused are invalidated
and eventually deleted.
(You can still create such a Secret by hand – type
`kubernetes.io/service-account-token` – but it never expires; avoid it.) The kubelet requests a token via the TokenRequest
API and mounts it, together with the cluster CA and the namespace, at
`/var/run/secrets/kubernetes.io/serviceaccount/`:

* **bound** – the token names the pod (and node) it belongs to; once that pod
  is deleted the token stops working (lab step 4),
* **audience-scoped** – valid only for the audience it was requested for,
* **time-limited** – the kubelet rotates it before it expires.

`automountServiceAccountToken: false` (on the ServiceAccount or the pod; the
pod wins) skips the mount. Do that for every pod that doesn't call the API –
most application pods don't.

### RBAC objects

```
       WHAT may be done                         WHO gets it, and WHERE
┌──────────────────────────────┐        ┌───────────────────────────────────────────┐
│ Role         (namespaced)    │◄───────│ RoleBinding (namespaced)                  │
│ ClusterRole  (cluster-wide)  │◄──┬────│   -> rules apply in the binding's namespace│
└──────────────────────────────┘   └────│ ClusterRoleBinding                        │
   rules: apiGroups x resources x verbs │   -> rules apply in ALL namespaces + to    │
                                        │      cluster-scoped resources (nodes, PVs) │
                                        └───────────────────────────────────────────┘
```

| Combination | Grants | Example |
|---|---|---|
| Role + RoleBinding | rules in that namespace | read pods in `lab-rbac` (04) |
| ClusterRole + RoleBinding | rules in the **binding's** namespace only | `view` for one team in one namespace (05) |
| ClusterRole + ClusterRoleBinding | rules everywhere, incl. cluster-scoped resources | read nodes (06) |
| Role + ClusterRoleBinding | not possible | — |

RBAC is **additive only**: no deny rules, permissions from all bindings are
unioned, and the default is "forbidden". A binding's `roleRef` is immutable
(delete and recreate the binding to change it).

Rules are `apiGroups` × `resources` × `verbs` (optionally `resourceNames`).
`kubectl api-resources -o wide` lists every resource with its group and verbs.
Subresources are separate: `pods/log`, `pods/exec`, `pods/portforward`,
`deployments/scale`.

### Built-in ClusterRoles

| ClusterRole | Intended binding | Can |
|---|---|---|
| `cluster-admin` | ClusterRoleBinding (break-glass only) | everything, everywhere |
| `admin` | RoleBinding per namespace | everything in the namespace incl. Roles/RoleBindings – not the namespace itself or ResourceQuotas |
| `edit` | RoleBinding | read/write most objects incl. Secrets, exec into pods – but no Roles/RoleBindings |
| `view` | RoleBinding | read most objects – **not** Secrets, not Roles/RoleBindings |

`admin`, `edit` and `view` are **aggregated** ClusterRoles: their rules are
the union of every ClusterRole labelled `rbac.authorization.k8s.io/aggregate-to-view: "true"`
(etc.), so CRD operators can extend them (07 shows the mechanism with our own
label).

### Least privilege – the rules of thumb

* One ServiceAccount per workload; never grant permissions to `default`.
* Prefer Role + RoleBinding; use ClusterRoleBindings only for truly
  cluster-wide needs.
* No wildcards (`*`) in verbs or resources – a `*` today also covers resources
  added tomorrow.
* Treat these as admin-equivalent: `get/list secrets`, `create pods` (a pod
  can run as **any** ServiceAccount in its namespace – Exercise 6), `pods/exec`,
  `escalate`, `bind`, `impersonate`, write access to RBAC objects, nodes or
  webhooks.
* Don't mount tokens into pods that don't need them.
* Verify with `kubectl auth can-i` instead of trusting your YAML.

## Files

| File | What it demonstrates |
|---|---|
| [`00-namespace.yaml`](00-namespace.yaml) | The `lab-rbac` namespace |
| [`01-serviceaccounts.yaml`](01-serviceaccounts.yaml) | Five ServiceAccounts, one with `automountServiceAccountToken: false` |
| [`02-token-pods.yaml`](02-token-pods.yaml) | A pod with the auto-mounted token and one without |
| [`03-kubectl-pod.yaml`](03-kubectl-pod.yaml) | `rancher/kubectl` pod listing pods with its SA token (Forbidden until 04) |
| [`04-role-pod-reader.yaml`](04-role-pod-reader.yaml) | Role + RoleBinding: read-only pods in `lab-rbac` |
| [`05-clusterrole-rolebinding.yaml`](05-clusterrole-rolebinding.yaml) | ClusterRoles reused in one namespace (own role + built-in `view`) |
| [`06-clusterrolebinding.yaml`](06-clusterrolebinding.yaml) | ClusterRoleBinding for a cluster-scoped resource (nodes) |
| [`07-aggregated-clusterrole.yaml`](07-aggregated-clusterrole.yaml) | An aggregated ClusterRole assembled by label |
| [`08-sample-data.yaml`](08-sample-data.yaml) | A ConfigMap and a Secret to test permissions against |
| [`solutions/`](solutions/) | Reference answers for the exercises |

Cluster-scoped objects created by this module (deleted in *Cleanup*):
ClusterRoles `lab-rbac-configmap-reader`, `lab-rbac-node-reader`,
`lab-rbac-monitoring`, `lab-rbac-monitoring-pods`,
`lab-rbac-monitoring-discovery`; ClusterRoleBinding `lab-rbac-node-watcher`.

## Lab

Run all commands from the repo root.

### 1. Who am I?

```bash
kubectl auth whoami
kubectl get clusterrolebinding kubeadm:cluster-admins -o wide
```

```
ATTRIBUTE                                           VALUE
Username                                            kubernetes-admin
Groups                                              [kubeadm:cluster-admins system:authenticated]
Extra: authentication.kubernetes.io/credential-id   [X509SHA256=38e33f95fb34...]

NAME                     ROLE                        AGE   USERS   GROUPS                   SERVICEACCOUNTS
kubeadm:cluster-admins   ClusterRole/cluster-admin   19m           kubeadm:cluster-admins
```

You authenticated with an X.509 client certificate (from your kubeconfig); the
certificate's CN became the username, its O the group, and a
ClusterRoleBinding makes that group `cluster-admin`. No `User` object anywhere.

### 2. ServiceAccounts and the token every pod gets

```bash
kubectl apply -f modules/11-rbac/00-namespace.yaml -f modules/11-rbac/01-serviceaccounts.yaml
kubectl -n lab-rbac get serviceaccounts
```

```
NAME            AGE
config-reader   0s
default         0s
no-api-access   0s
node-watcher    0s
pod-viewer      0s
viewer          0s
```

`default` appeared by itself (the ServiceAccount controller creates it in every
namespace). No token Secrets were created for any of them.

```bash
kubectl apply -f modules/11-rbac/02-token-pods.yaml
kubectl -n lab-rbac wait --for=condition=Ready pod/token-mounted pod/no-token
kubectl -n lab-rbac exec token-mounted -- ls /var/run/secrets/kubernetes.io/serviceaccount
kubectl -n lab-rbac exec no-token -- ls /var/run/secrets/kubernetes.io/serviceaccount
kubectl -n lab-rbac get pod token-mounted -o jsonpath='{.spec.volumes[0]}{"\n"}'
```

```
ca.crt
namespace
token
ls: /var/run/secrets/kubernetes.io/serviceaccount: No such file or directory
command terminated with exit code 1
{"name":"kube-api-access-78zrb","projected":{"defaultMode":420,"sources":[{"serviceAccountToken":
{"expirationSeconds":3607,"path":"token"}},{"configMap":{"items":[{"key":"ca.crt","path":"ca.crt"}],
"name":"kube-root-ca.crt"}},{"downwardAPI":{"items":[{"fieldRef":{"apiVersion":"v1",
"fieldPath":"metadata.namespace"},"path":"namespace"}]}}]}}
```

The admission controller added a **projected volume** with three sources: a
`serviceAccountToken`, the `kube-root-ca.crt` ConfigMap and the namespace via
the downward API ([module 05](../05-config-secrets/README.md)). Decode the
token's payload (a JWT is `header.payload.signature`, base64url-encoded):

```bash
jwt() { cut -d. -f2 | tr '_-' '/+' | awk '{while (length($0)%4) $0=$0"="; print}' | base64 -d; echo; }
kubectl -n lab-rbac exec token-mounted -- cat /var/run/secrets/kubernetes.io/serviceaccount/token | jwt
```

```json
{"aud":["https://kubernetes.default.svc.cluster.local"],"exp":1822992904,"iat":1791456904,
 "iss":"https://kubernetes.default.svc.cluster.local","jti":"46f15b07-...",
 "kubernetes.io":{"namespace":"lab-rbac",
   "node":{"name":"kube-training-worker","uid":"e5a20e6f-..."},
   "pod":{"name":"token-mounted","uid":"f9621301-..."},
   "serviceaccount":{"name":"default","uid":"7ee753ac-..."},
   "warnafter":1791460511},
 "nbf":1791456904,"sub":"system:serviceaccount:lab-rbac:default"}
```

* `sub` – the username RBAC will see.
* `kubernetes.io.pod` / `node` – the objects the token is **bound** to.
* `warnafter` is `iat` + 1 h (the requested 3607 s), but `exp` is a year later:
  the API server extends kubelet-mounted tokens so that old client libraries
  that never re-read the file keep working, and logs a warning when a token is
  used after `warnafter`. The kubelet replaces the file well before that.

### 3. A pod running kubectl: Forbidden

```bash
kubectl apply -f modules/11-rbac/03-kubectl-pod.yaml
kubectl -n lab-rbac get pod kubectl-client            # wait for Error
kubectl -n lab-rbac logs kubectl-client
```

```
NAME             READY   STATUS   RESTARTS   AGE
kubectl-client   0/1     Error    0          3s

Error from server (Forbidden): pods is forbidden: User "system:serviceaccount:lab-rbac:pod-viewer"
cannot list resource "pods" in API group "" in the namespace "lab-rbac"
```

Read the error carefully – it tells you everything you need to write the rule:
**who** (`system:serviceaccount:lab-rbac:pod-viewer`), **verb** (`list`),
**resource** (`pods`), **API group** (`""` = core) and **namespace**
(`lab-rbac`). Authentication worked (otherwise: 401 Unauthorized); there is
simply no binding that allows it. Fix it with a Role + RoleBinding and run the
pod again:

```bash
kubectl apply -f modules/11-rbac/04-role-pod-reader.yaml
kubectl replace --force -f modules/11-rbac/03-kubectl-pod.yaml
kubectl -n lab-rbac logs kubectl-client
```

```
role.rbac.authorization.k8s.io/pod-reader created
rolebinding.rbac.authorization.k8s.io/pod-viewer-reads-pods created
pod "kubectl-client" deleted from lab-rbac namespace
pod/kubectl-client replaced

NAME             READY   STATUS    RESTARTS   AGE
kubectl-client   1/1     Running   0          1s
no-token         1/1     Running   0          8s
token-mounted    1/1     Running   0          8s
```

RBAC changes take effect immediately – no restart of anything needed.

### 4. `kubectl create token` and bound tokens

You can request a token for any ServiceAccount yourself (TokenRequest API) –
handy for CI systems and for testing:

```bash
TOKEN=$(kubectl -n lab-rbac create token pod-viewer --duration=10m)
echo "$TOKEN" | jwt
```

```json
{"aud":["https://kubernetes.default.svc.cluster.local"],"exp":1791457514,"iat":1791456914, ...
 "kubernetes.io":{"namespace":"lab-rbac","serviceaccount":{"name":"pod-viewer","uid":"1b215959-..."}},
 "sub":"system:serviceaccount:lab-rbac:pod-viewer"}
```

Exactly 10 minutes, and not bound to any pod. Use it **instead of** your admin
certificate. (`kubectl --token=...` with your normal kubeconfig would still
send the client certificate too, and you'd stay admin – so start from an empty
kubeconfig:)

```bash
SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' \
  | base64 -d > /tmp/lab-rbac-ca.crt
sa() { kubectl --kubeconfig=/dev/null --server="$SERVER" --certificate-authority=/tmp/lab-rbac-ca.crt "$@"; }

sa --token="$TOKEN" auth whoami
sa --token="$TOKEN" -n lab-rbac get pods
sa --token="$TOKEN" -n lab-rbac get secrets
```

```
ATTRIBUTE                                           VALUE
Username                                            system:serviceaccount:lab-rbac:pod-viewer
UID                                                 1b215959-e34e-4efa-8aab-750d386984da
Groups                                              [system:serviceaccounts system:serviceaccounts:lab-rbac system:authenticated]
Extra: authentication.kubernetes.io/credential-id   [JTI=0979799b-16a4-487e-974f-da931574f1da]

NAME             READY   STATUS      RESTARTS   AGE
kubectl-client   0/1     Completed   0          3s
...
Error from server (Forbidden): secrets is forbidden: User "system:serviceaccount:lab-rbac:pod-viewer" cannot list resource "secrets" ...
```

Now a token **bound to a pod**. The pod must run as the same ServiceAccount
(`token-mounted` runs as `default`, so it is refused):

```bash
kubectl -n lab-rbac create token pod-viewer --bound-object-kind=Pod --bound-object-name=token-mounted
# error: failed to create token: cannot bind token for serviceaccount "pod-viewer" to pod running with different serviceaccount name.

kubectl -n lab-rbac get pod kubectl-client                    # from step 3, runs as pod-viewer
BOUND=$(kubectl -n lab-rbac create token pod-viewer --bound-object-kind=Pod --bound-object-name=kubectl-client --duration=10m)
sa --token="$BOUND" -n lab-rbac get pods -o name               # works
kubectl -n lab-rbac delete pod kubectl-client
sa --token="$BOUND" -n lab-rbac get pods -o name               # repeat for ~10 s
```

```
pod/kubectl-client
pod/no-token
pod/token-mounted
pod "kubectl-client" deleted from lab-rbac namespace
pod/no-token                     <- still accepted for a few seconds (auth cache)
...
error: You must be logged in to the server (Unauthorized)
```

Within about 10 seconds (the API server briefly caches successful token
checks) the token is dead – even though it hasn't expired. A token stolen from
a pod is useless once the pod is gone. That's the "bound" in bound tokens.

### 5. Reusing ClusterRoles, ClusterRoleBindings, aggregation

```bash
kubectl apply -f modules/11-rbac/05-clusterrole-rolebinding.yaml \
              -f modules/11-rbac/06-clusterrolebinding.yaml \
              -f modules/11-rbac/07-aggregated-clusterrole.yaml \
              -f modules/11-rbac/08-sample-data.yaml
kubectl get clusterrole lab-rbac-monitoring -o yaml | sed -n '/^rules:/,$p'
```

```yaml
rules:
- apiGroups:
  - discovery.k8s.io
  resources:
  - endpointslices
  verbs: [get, list, watch]          # (printed one per line)
- apiGroups:
  - ""
  resources:
  - pods
  - services
  verbs: [get, list, watch]
```

We wrote `rules: []` – the controller manager filled in the rules of the two
labelled ClusterRoles. The built-ins work the same way:

```bash
kubectl get clusterrole view -o jsonpath='{.aggregationRule}{"\n"}'
```

```
{"clusterRoleSelectors":[{"matchLabels":{"rbac.authorization.k8s.io/aggregate-to-view":"true"}}]}
```

### 6. The `kubectl auth can-i` matrix

`--as` impersonates another identity (you're allowed to because you're
cluster-admin). For a ServiceAccount username, the API server adds the SA's
groups automatically:

```bash
kubectl auth whoami --as=system:serviceaccount:lab-rbac:viewer
```

```
ATTRIBUTE   VALUE
Username    system:serviceaccount:lab-rbac:viewer
Groups      [system:serviceaccounts system:serviceaccounts:lab-rbac system:authenticated]
```

Now check every ServiceAccount against a few typical actions:

```bash
printf '%-14s %-6s %-6s %-6s %-6s %-6s %-6s %-6s\n' SA pods logs cm cm@def secret deploy nodes
for sa in default pod-viewer config-reader viewer node-watcher; do
  as="--as=system:serviceaccount:lab-rbac:$sa"
  printf '%-14s %-6s %-6s %-6s %-6s %-6s %-6s %-6s\n' "$sa" \
    "$(kubectl auth can-i list pods                  -n lab-rbac $as)" \
    "$(kubectl auth can-i get pods --subresource=log -n lab-rbac $as)" \
    "$(kubectl auth can-i list configmaps            -n lab-rbac $as)" \
    "$(kubectl auth can-i list configmaps            -n default  $as)" \
    "$(kubectl auth can-i get secrets                -n lab-rbac $as)" \
    "$(kubectl auth can-i create deployments.apps    -n lab-rbac $as)" \
    "$(kubectl auth can-i list nodes                 -A          $as)"
done
```

```
SA             pods   logs   cm     cm@def secret deploy nodes
default        no     no     no     no     no     no     no
pod-viewer     yes    no     no     no     no     no     no
config-reader  no     no     yes    no     no     no     no
viewer         yes    yes    yes    no     no     no     no
node-watcher   no     no     no     no     no     no     yes
```

What to notice:

* `default` can do nothing – keep it that way.
* `pod-viewer` can list pods but **not** read their logs (`pods/log` is a
  separate resource).
* `config-reader` and `viewer` got ClusterRoles through a **RoleBinding**, so
  only in `lab-rbac` (`cm@def` = configmaps in `default`: no).
* `viewer` (`view`) can't read Secrets – by design.
* Only `node-watcher` (ClusterRoleBinding) can see nodes. Cluster-scoped
  resources can't be granted with a RoleBinding at all. (`-A` just avoids a
  warning that nodes aren't namespaced.)

Prove the matrix with real requests:

```bash
kubectl -n lab-rbac get configmaps,secrets --as=system:serviceaccount:lab-rbac:viewer
```

```
NAME               DATA   AGE
app-config         1      5s
kube-root-ca.crt   1      37s
Error from server (Forbidden): secrets is forbidden: User "system:serviceaccount:lab-rbac:viewer" cannot list resource "secrets" in API group "" in the namespace "lab-rbac"
```

And ask "what can this identity do here?":

```bash
kubectl auth can-i --list -n lab-rbac --as=system:serviceaccount:lab-rbac:pod-viewer
```

```
Resources                                       Non-Resource URLs   Resource Names   Verbs
selfsubjectreviews.authentication.k8s.io        []                  []               [create]
selfsubjectaccessreviews.authorization.k8s.io   []                  []               [create]
selfsubjectrulesreviews.authorization.k8s.io    []                  []               [create]
pods                                            []                  []               [get list watch]
clustertrustbundles.certificates.k8s.io         []                  []               [get list watch]
                                                [/api/*]            []               [get]
                                                [/version]          []               [get]
...
```

Only the `pods` line is ours. The `self*reviews`, `clustertrustbundles` and
non-resource URLs (`/api`, `/healthz`, `/version`...) come from built-in
ClusterRoles bound to the groups `system:authenticated` /
`system:serviceaccounts` (`system:basic-user`, `system:discovery`,
`system:public-info-viewer`, `system:service-account-issuer-discovery`,
`system:cluster-trust-bundle-discovery`).

## Exercises

1. **What can `default` do?** Run `kubectl auth can-i --list` for the
   `default` ServiceAccount of `lab-rbac`, and then for yourself (no `--as`).
   Which ClusterRoleBindings explain the difference?
   *Hint:* `kubectl get clusterrolebindings -o wide | grep -E 'system:(authenticated|serviceaccounts)'`.

2. **Logs, please.** Make `kubectl logs` work for `pod-viewer` in `lab-rbac`
   without giving it anything else. Verify with
   `kubectl auth can-i get pods --subresource=log -n lab-rbac --as=...` and with
   `kubectl -n lab-rbac logs token-mounted --as=...`.
   Solution: [`solutions/02-pod-reader-with-logs.yaml`](solutions/02-pod-reader-with-logs.yaml).

3. **All namespaces.** Change the kubectl pod's args to
   `["get", "pods", "--all-namespaces"]`. Read the new error (`... at the
   cluster scope`) and fix it. Why can't a RoleBinding fix it, even one that
   points at a ClusterRole? Remove the cluster-wide grant afterwards.
   Solution: [`solutions/03-cluster-pod-reader.yaml`](solutions/03-cluster-pod-reader.yaml).

4. **A CI deployer.** Create a ServiceAccount `deployer` that can create,
   update, scale and delete Deployments in `lab-rbac` and watch their rollout
   – but can't read Secrets, can't `exec`, and can't touch any other
   namespace. Test it end-to-end with `--as`:
   `kubectl -n lab-rbac create deployment hello --image=traefik/whoami:v1.10 --dry-run=client -o yaml | kubectl apply --as=system:serviceaccount:lab-rbac:deployer -f -`,
   then `scale`, `rollout status`, `get secrets`, `exec`.
   *Hint:* `kubectl scale` fails until you grant the `deployments/scale`
   subresource.
   Solution: [`solutions/04-deployer.yaml`](solutions/04-deployer.yaml).

5. **A human user with a client certificate.** Create user `jane` (group
   `training-devs`) with the CertificateSigningRequest API, put her
   credentials in a **separate** kubeconfig file, and give her `view` in
   `lab-rbac` only.
   *Hint* (run in an empty scratch directory):

   ```bash
   openssl genrsa -out jane.key 2048
   openssl req -new -key jane.key -subj "/CN=jane/O=training-devs" -out jane.csr
   cat <<EOF | kubectl apply -f -
   apiVersion: certificates.k8s.io/v1
   kind: CertificateSigningRequest
   metadata:
     name: lab-rbac-jane
   spec:
     request: $(base64 < jane.csr | tr -d '\n')
     signerName: kubernetes.io/kube-apiserver-client
     expirationSeconds: 86400
     usages: ["client auth"]
   EOF
   kubectl certificate approve lab-rbac-jane
   kubectl get csr lab-rbac-jane -o jsonpath='{.status.certificate}' | base64 -d > jane.crt

   SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
   kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d > ca.crt
   kubectl --kubeconfig=jane.kubeconfig config set-cluster kube-training --server="$SERVER" --certificate-authority=ca.crt --embed-certs
   kubectl --kubeconfig=jane.kubeconfig config set-credentials jane --client-certificate=jane.crt --client-key=jane.key --embed-certs
   kubectl --kubeconfig=jane.kubeconfig config set-context jane --cluster=kube-training --user=jane --namespace=lab-rbac
   kubectl --kubeconfig=jane.kubeconfig config use-context jane
   kubectl --kubeconfig=jane.kubeconfig auth whoami      # Username jane, Groups [training-devs system:authenticated]
   kubectl --kubeconfig=jane.kubeconfig get pods         # Forbidden ... until you apply the solution
   ```

   Solution: [`solutions/05-user-jane.yaml`](solutions/05-user-jane.yaml).
   Then think about this: how would you *revoke* jane's certificate?
   (You can't – Kubernetes has no certificate revocation. Remove her
   RoleBindings and wait for expiry. That's why real clusters use OIDC for
   humans.) Clean up with `kubectl delete csr lab-rbac-jane`.

6. **"Only create pods" is not harmless.** Apply
   [`solutions/06-pod-creator.yaml`](solutions/06-pod-creator.yaml): a
   ServiceAccount that may *only* create pods. Confirm it can't list nodes
   (`kubectl get nodes --as=system:serviceaccount:lab-rbac:pod-creator`).
   Now find a way for it to list nodes anyway.
   *Hint:* which ServiceAccounts exist in `lab-rbac`, and who decides which
   one a pod runs as? Solution:
   [`solutions/06-sneaky-pod.yaml`](solutions/06-sneaky-pod.yaml) – create it
   with `kubectl create -f ... --as=system:serviceaccount:lab-rbac:pod-creator`
   (plain `create`, because `apply` would also need `get`), then read its logs
   as yourself.

## Cleanup

```bash
kubectl delete namespace lab-rbac
kubectl delete clusterrole lab-rbac-configmap-reader lab-rbac-node-reader \
  lab-rbac-monitoring lab-rbac-monitoring-pods lab-rbac-monitoring-discovery
kubectl delete clusterrolebinding lab-rbac-node-watcher
# Exercises 3 and 5, if you did them:
kubectl delete clusterrole lab-rbac-pod-reader-all --ignore-not-found
kubectl delete clusterrolebinding lab-rbac-pod-viewer-all --ignore-not-found
kubectl delete csr lab-rbac-jane --ignore-not-found
rm -f /tmp/lab-rbac-ca.crt

# Check nothing is left
kubectl get clusterroles,clusterrolebindings | grep lab-rbac
```

Deleting the namespace removes the ServiceAccounts, Roles and RoleBindings in
it. ClusterRoles and ClusterRoleBindings are cluster-scoped and survive a
namespace deletion – even a ClusterRoleBinding whose subject was a
ServiceAccount in the deleted namespace. (If someone recreates a ServiceAccount
with the same name, it inherits that binding. Always clean up cluster-scoped
bindings.)

## Further reading

* [Controlling Access to the Kubernetes API](https://kubernetes.io/docs/concepts/security/controlling-access/)
* [Authenticating](https://kubernetes.io/docs/reference/access-authn-authz/authentication/) – certificates, tokens, OIDC, impersonation
* [Using RBAC Authorization](https://kubernetes.io/docs/reference/access-authn-authz/rbac/)
* [Role Based Access Control Good Practices](https://kubernetes.io/docs/concepts/security/rbac-good-practices/)
* [Service Accounts](https://kubernetes.io/docs/concepts/security/service-accounts/) and
  [Configure Service Accounts for Pods](https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/)
* [Managing Service Accounts](https://kubernetes.io/docs/reference/access-authn-authz/service-accounts-admin/) – bound tokens, TokenRequest
* [Certificates and Certificate Signing Requests](https://kubernetes.io/docs/reference/access-authn-authz/certificate-signing-requests/)
* [`kubectl auth can-i`](https://kubernetes.io/docs/reference/kubectl/generated/kubectl_auth/kubectl_auth_can-i/)
