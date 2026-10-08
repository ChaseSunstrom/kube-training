# 02 – Namespaces & labels

## Goal

Organise a cluster: split it into namespaces with their own budgets and
defaults, and use labels, selectors and annotations to find, group and
connect objects.

## What you'll learn

* What a namespace is (and isn't), and which resources are namespaced
* Labels vs annotations, and the rules for each
* Equality-based (`env=prod`, `env!=prod`) and set-based (`env in (dev,qa)`, `!track`) selectors; `--show-labels`, `-L`
* How controllers use selectors – and how relabelling a pod "quarantines" it from its ReplicaSet
* The recommended `app.kubernetes.io/*` labels
* **ResourceQuota**: per-namespace budgets, and what happens when you exceed one
* **LimitRange**: per-container defaults, minimums and maximums

## Concepts

### Namespaces

A namespace is a **name scope** for objects plus a **unit of policy**:

* Names must be unique per namespace and kind, so `lab-namespaces-team-a/app` and `lab-namespaces-team-b/app` are two different pods.
* Policies attach to namespaces: RBAC RoleBindings (module 11), ResourceQuota and LimitRange (this module), NetworkPolicies (module 13), Pod Security Admission labels (module 15).
* Deleting a namespace deletes **everything** in it – that is why every module here cleans up with one command.

What a namespace is **not**: it is not a network boundary (pods in different
namespaces can talk to each other freely until you add NetworkPolicies) and
not a node boundary (pods of all namespaces share the same nodes).

Not everything lives in a namespace. **Cluster-scoped** resources include
Nodes, Namespaces themselves, PersistentVolumes, StorageClasses,
ClusterRoles/ClusterRoleBindings, PriorityClasses, IngressClasses and
CustomResourceDefinitions. Ask the cluster:

```bash
kubectl api-resources --namespaced=false
kubectl api-resources --namespaced=true
```

Every cluster starts with `default` (where things land when you forget
`-n`), `kube-system` (control-plane add-ons), `kube-public` (readable by
everyone) and `kube-node-lease` (node heartbeats).

### Labels

Labels are key/value pairs used to **identify and select** objects.

* Key: optional prefix + name, e.g. `app.kubernetes.io/name` or `tier`. The name part is ≤ 63 chars of `[a-z0-9A-Z-_.]`, starting and ending alphanumeric; the prefix is a DNS subdomain. `kubernetes.io/` and `k8s.io/` prefixes are reserved for Kubernetes itself.
* Value: ≤ 63 chars, same character set, may be empty.
* Every object can have labels, and selectors can find any kind of object: `kubectl get nodes -l training/zone=zone-a`, `kubectl get ns -l team`.

**Selectors** come in two flavours:

| Kind | Syntax (`kubectl -l`) | In YAML |
|---|---|---|
| equality | `env=prod`, `env==prod`, `env!=prod` | `matchLabels: {env: prod}`; Service `selector:` (equality only) |
| set-based | `env in (dev,qa)`, `env notin (prod)`, `track` (key exists), `!track` (key absent) | `matchExpressions: [{key: env, operator: In, values: [dev, qa]}]` |

A comma means **AND**: `-l app=web,env!=prod`. There is no OR across
different keys – for that you run two queries. Careful: `env!=prod` and
`env notin (prod)` also match objects that have **no** `env` label at all.

Selectors are the glue of Kubernetes: a ReplicaSet/Deployment finds its pods,
a Service finds its endpoints, a NetworkPolicy finds the pods it protects,
all **by label, at the time they look**. Nothing stores "these are my pods".

### Annotations

Annotations are key/value metadata **for tools and humans**, never used for
selection. Values can be long (total for all annotations ≤ 256 KiB) and
contain anything: URLs, JSON, commit hashes. You have already seen
`kubectl.kubernetes.io/last-applied-configuration` (module 00); others you
will meet: `kubernetes.io/change-cause` (module 03),
`controller.kubernetes.io/pod-deletion-cost`, ingress-controller settings.

### Recommended labels

Shared labels let tools (Helm, Argo CD, dashboards, `kubectl`) understand an
app without guessing:

| Label | Example | Meaning |
|---|---|---|
| `app.kubernetes.io/name` | `frontend` | the application |
| `app.kubernetes.io/instance` | `frontend-lab` | this installation of it (unique) |
| `app.kubernetes.io/version` | `"1.27"` | app version |
| `app.kubernetes.io/component` | `web` | role in the architecture |
| `app.kubernetes.io/part-of` | `shop` | the larger system |
| `app.kubernetes.io/managed-by` | `helm` | the tool that manages it |

This repo additionally puts a short `app: <name>` on everything (see
[`docs/CONVENTIONS.md`](../../docs/CONVENTIONS.md)) because it keeps selectors readable.

### ResourceQuota and LimitRange

```
            CREATE pod in lab-namespaces-team-a
                            │
   LimitRanger admission ───┤ fill in missing requests/limits (defaultRequest/default)
                            │ reject if a container is outside [min, max]
   ResourceQuota admission ─┤ reject if namespace totals would exceed `hard`
                            │ reject if quota tracks cpu/memory and the pod declares none
                            ▼
                      stored in etcd
```

* **ResourceQuota** caps the **sum** over a namespace: compute (`requests.cpu`, `limits.memory`…), storage (`requests.storage`, `persistentvolumeclaims`) and object counts (`pods`, `services.nodeports`, `count/deployments.apps`…).
* **LimitRange** sets **per-container (or per-pod / per-PVC) defaults and bounds**.
* Both act only at admission time. Lowering a quota never kills running pods; it just blocks new ones.

## Files

| File | What it demonstrates |
|---|---|
| [`00-namespace.yaml`](00-namespace.yaml) | Three labelled namespaces: `lab-namespaces`, `lab-namespaces-team-a`, `lab-namespaces-team-b` |
| [`01-labelled-pods.yaml`](01-labelled-pods.yaml) | Six pods with `app`/`env`/`tier`/`track` labels and some annotations – selector practice |
| [`02-replicaset.yaml`](02-replicaset.yaml) | A ReplicaSet with `matchLabels` + `matchExpressions` and the recommended labels |
| [`03-same-name-pods.yaml`](03-same-name-pods.yaml) | Two pods called `app` in two namespaces |
| [`04-resourcequota.yaml`](04-resourcequota.yaml) | Compute, storage and object-count quota for team-a |
| [`05-limitrange.yaml`](05-limitrange.yaml) | Default requests/limits, min and max per container for team-a |
| [`06-pod-defaults.yaml`](06-pod-defaults.yaml) | A pod without resources that gets them from the LimitRange |
| [`07-quota-filler.yaml`](07-quota-filler.yaml) | A ReplicaSet that runs into the `pods` quota |
| [`exercises/`](exercises/), [`solutions/`](solutions/) | Exercise starting points and reference answers |

## Lab

### 1. Namespaces

```bash
kubectl apply -f modules/02-namespaces-labels/00-namespace.yaml
kubectl get namespaces -l app=namespaces --show-labels
```

```
NAME                    STATUS   AGE   LABELS
lab-namespaces          Active   6s    app=namespaces,kubernetes.io/metadata.name=lab-namespaces
lab-namespaces-team-a   Active   6s    app=namespaces,env=dev,kubernetes.io/metadata.name=lab-namespaces-team-a,team=a
lab-namespaces-team-b   Active   5s    app=namespaces,env=prod,kubernetes.io/metadata.name=lab-namespaces-team-b,team=b
```

The API server adds `kubernetes.io/metadata.name` to every namespace, so
policies can select a namespace by name (module 13). Namespaces are
selectable like anything else: `kubectl get ns -l team` lists only the two
team namespaces.

Same name, two namespaces:

```bash
kubectl apply -f modules/02-namespaces-labels/03-same-name-pods.yaml
kubectl get pods -A -l app=same-name
kubectl get pod app          # no -n: looks in `default`
```

```
NAMESPACE               NAME   READY   STATUS    RESTARTS   AGE
lab-namespaces-team-a   app    1/1     Running   0          16s
lab-namespaces-team-b   app    1/1     Running   0          16s
Error from server (NotFound): pods "app" not found
```

"NotFound" while the pod obviously exists is almost always "wrong namespace"
(or wrong context). Use `-A` (`--all-namespaces`) when hunting.

### 2. Labels and selectors

```bash
kubectl apply -f modules/02-namespaces-labels/01-labelled-pods.yaml
kubectl get pods -n lab-namespaces --show-labels
kubectl get pods -n lab-namespaces -L env,tier,track      # labels as columns
```

```
NAME              READY   STATUS    RESTARTS   AGE   ENV    TIER       TRACK
api-dev           1/1     Running   0          5s    dev    backend
api-prod          1/1     Running   0          5s    prod   backend    stable
web-dev           1/1     Running   0          5s    dev    frontend
web-prod          1/1     Running   0          5s    prod   frontend   stable
web-prod-canary   1/1     Running   0          5s    prod   frontend   canary
web-qa            1/1     Running   0          5s    qa     frontend
```

Try each selector and predict the result before you press Enter:

```bash
kubectl get pods -n lab-namespaces -l env=prod                    # api-prod, web-prod, web-prod-canary
kubectl get pods -n lab-namespaces -l app=web,env!=prod           # web-dev, web-qa           (AND)
kubectl get pods -n lab-namespaces -l 'env in (dev,qa)'           # api-dev, web-dev, web-qa
kubectl get pods -n lab-namespaces -l track                       # has the key: the 3 prod pods
kubectl get pods -n lab-namespaces -l '!track'                    # lacks the key: the other 3
kubectl get pods -n lab-namespaces -l 'app in (web,api),track=stable'   # api-prod, web-prod
```

Quote set-based selectors: `(`, `)` and `!` mean something to your shell.

Change labels on a live object (`--overwrite` is required to change an
existing value; a trailing `-` removes a key):

```bash
kubectl label pod web-qa -n lab-namespaces owner=alice
kubectl label pod web-qa -n lab-namespaces env=staging              # error: 'env' already has a value (qa)
kubectl label pod web-qa -n lab-namespaces env=staging --overwrite
kubectl label pod web-qa -n lab-namespaces owner- env=qa --overwrite
kubectl get pod web-qa -n lab-namespaces --show-labels             # back to app=web,env=qa,tier=frontend
```

The API validates labels:

```bash
kubectl label pod web-dev -n lab-namespaces 'bad label=x'
```

```
The Pod "web-dev" is invalid: metadata.labels: Invalid value: "bad label": name part must consist of
alphanumeric characters, '-', '_' or '.', and must start and end with an alphanumeric character ...
```

Selectors work with every verb, which makes them powerful *and*
dangerous: `kubectl delete pods -l env=dev -n lab-namespaces` deletes every
match. Run the same selector with `get` first.

### 3. Annotations

```bash
kubectl annotate pod web-qa -n lab-namespaces training/description="QA copy of the web frontend"
kubectl describe pod web-prod -n lab-namespaces | sed -n '/^Labels/,/^Status/p'
```

```
Labels:           app=web
                  env=prod
                  tier=frontend
                  track=stable
Annotations:      training/git-commit: 3f9c2a1d4e5b6f708192a3b4c5d6e7f8091a2b3c
                  training/runbook: https://wiki.example.com/runbooks/web
Status:           Running
```

A URL or a 40-character hash could never be a label value (`/` and `:` are
not allowed, and values are limited to 63 characters); as annotations they
are fine. And you cannot select on them – `-l training/runbook` finds nothing.

### 4. Selectors link objects: quarantine a pod

```bash
kubectl apply -f modules/02-namespaces-labels/02-replicaset.yaml
kubectl get pods -n lab-namespaces -l app=frontend
POD=$(kubectl get pods -n lab-namespaces -l app=frontend -o jsonpath='{.items[0].metadata.name}')
kubectl get pod $POD -n lab-namespaces -o jsonpath='{.metadata.ownerReferences[0].kind}/{.metadata.ownerReferences[0].name}{"\n"}'
```

```
ReplicaSet/frontend
```

Imagine this pod misbehaves and you want to debug it **without** it serving
traffic and **without** losing capacity. Change the label the ReplicaSet
(and any Service) selects on:

```bash
kubectl label pod $POD -n lab-namespaces app=frontend-quarantine --overwrite
kubectl get pods -n lab-namespaces -l 'app in (frontend,frontend-quarantine)' -L app
```

```
NAME             READY   STATUS              RESTARTS   AGE   APP
frontend-62tng   1/1     Running             0          32s   frontend-quarantine
frontend-ch4t6   0/1     ContainerCreating   0          0s    frontend
frontend-fpljz   1/1     Running             0          32s   frontend
frontend-h7dw2   1/1     Running             0          32s   frontend
```

The ReplicaSet counted only 2 matching pods, so it created a replacement.
It also **released** the old pod: its `ownerReferences` are gone, so it is a
standalone pod now – still running, still reachable with `kubectl exec`, and
it will not be deleted if you delete the ReplicaSet:

```bash
kubectl get pod $POD -n lab-namespaces -o jsonpath='owners={.metadata.ownerReferences}{"\n"}'   # owners=
kubectl exec $POD -n lab-namespaces -- wget -qO- localhost | head -4
```

Put it back and the ReplicaSet re-adopts it, finds 4 pods, and deletes one –
normally the one that has been ready for the shortest time, i.e. the
replacement:

```bash
kubectl label pod $POD -n lab-namespaces app=frontend --overwrite
kubectl get events -n lab-namespaces --field-selector involvedObject.kind=ReplicaSet | tail -1
```

```
0s          Normal   SuccessfulDelete   replicaset/frontend   Deleted pod: frontend-ch4t6
```

### 5. ResourceQuota

```bash
kubectl apply -f modules/02-namespaces-labels/04-resourcequota.yaml
kubectl describe resourcequota team-a-quota -n lab-namespaces-team-a
```

```
Resource                Used  Hard
--------                ----  ----
count/configmaps        1     5
limits.cpu              20m   1
limits.memory           16Mi  512Mi
persistentvolumeclaims  0     2
pods                    1     4
requests.cpu            5m    200m
requests.memory         8Mi   256Mi
requests.storage        0     2Gi
services                0     5
services.nodeports      0     0
```

Usage is already non-zero: the `app` pod from step 1 counts, and so does the
`kube-root-ca.crt` ConfigMap that Kubernetes puts in every namespace. Now try
to create a pod without resources:

```bash
kubectl run no-limits --image=busybox:1.37 -n lab-namespaces-team-a -- sleep 3600
```

```
Error from server (Forbidden): pods "no-limits" is forbidden: failed quota: team-a-quota: must specify
limits.cpu for: no-limits; limits.memory for: no-limits; requests.cpu for: no-limits; requests.memory for: no-limits
```

Because the quota tracks CPU and memory, the API server cannot count a pod
that declares none – so it refuses it. The same command works in
`lab-namespaces-team-b`, which has no quota. The quota also forbids NodePort
Services in team-a:

```bash
kubectl create service nodeport np --tcp=80 -n lab-namespaces-team-a
```

```
error: failed to create NodePort service: services "np" is forbidden: exceeded quota: team-a-quota,
requested: services.nodeports=1, used: services.nodeports=0, limited: services.nodeports=0
```

### 6. LimitRange defaults

```bash
kubectl apply -f modules/02-namespaces-labels/05-limitrange.yaml
kubectl describe limitrange team-a-limits -n lab-namespaces-team-a
```

```
Type                   Resource  Min  Max    Default Request  Default Limit  Max Limit/Request Ratio
----                   --------  ---  ---    ---------------  -------------  -----------------------
Container              cpu       5m   500m   25m              100m           -
Container              memory    8Mi  256Mi  32Mi             64Mi           -
PersistentVolumeClaim  storage   -    1Gi    -                -              -
```

[`06-pod-defaults.yaml`](06-pod-defaults.yaml) has no `resources` at all –
the same mistake as `no-limits` – but now it is accepted:

```bash
kubectl apply -f modules/02-namespaces-labels/06-pod-defaults.yaml
kubectl get pod defaults-demo -n lab-namespaces-team-a -o jsonpath='{.spec.containers[0].resources}{"\n"}'
kubectl get pod defaults-demo -n lab-namespaces-team-a -o jsonpath='{.metadata.annotations.kubernetes\.io/limit-ranger}{"\n"}'
```

```
{"limits":{"cpu":"100m","memory":"64Mi"},"requests":{"cpu":"25m","memory":"32Mi"}}
LimitRanger plugin set: cpu, memory request for container app; cpu, memory limit for container app
```

The LimitRanger ran first and wrote the defaults into the pod, then the
quota check found everything it needed.

### 7. Exceeding a quota through a controller

```bash
kubectl apply -f modules/02-namespaces-labels/07-quota-filler.yaml
kubectl get rs filler -n lab-namespaces-team-a
kubectl get events -n lab-namespaces-team-a --field-selector reason=FailedCreate | tail -1
```

```
replicaset.apps/filler created
NAME     DESIRED   CURRENT   READY   AGE
filler   5         2         0       0s
Warning   FailedCreate   replicaset/filler   Error creating: pods "filler-vgnwx" is forbidden: exceeded quota:
team-a-quota, requested: pods=1, used: pods=4, limited: pods=4
```

`kubectl apply` said **created** – the ReplicaSet object fit the quota. Its
*pods* did not: two fit (4 pods total), three were refused, and the
controller keeps retrying in the background. This is a classic "my pods
never appear" support ticket: when DESIRED and CURRENT differ, read the
controller's events. `kubectl get resourcequota -n lab-namespaces-team-a`
shows the usage on one line.

## Exercises

1. **Selector drill.** In `lab-namespaces`, with one `kubectl get` each, list:
   (a) prod pods that are *not* canaries; (b) pods without an `env` label;
   (c) frontend pods in dev or qa; (d) all namespaces of team `a` or `b` that are `env=prod`.
   <details><summary>Answers</summary>

   (a) `-l env=prod,track!=canary` (or `-l 'env=prod,track notin (canary)'`);
   (b) `-l '!env'` – the three `frontend-*` pods;
   (c) `-l 'tier=frontend,env in (dev,qa)'`;
   (d) `kubectl get ns -l 'team in (a,b),env=prod'` – only team-b.
   </details>

2. **Choose who leaves.** Quarantine a `frontend` pod again (step 4), then
   make sure that when you put it back, the ReplicaSet deletes **that** pod
   instead of the replacement.
   *Hint:* the annotation `controller.kubernetes.io/pod-deletion-cost` (lower = deleted first).
   <details><summary>Solution</summary>

   ```bash
   kubectl annotate pod $POD -n lab-namespaces controller.kubernetes.io/pod-deletion-cost=-1000
   kubectl label pod $POD -n lab-namespaces app=frontend --overwrite
   kubectl get events -n lab-namespaces --field-selector involvedObject.kind=ReplicaSet | tail -1
   # Normal   SuccessfulDelete   replicaset/frontend   Deleted pod: <your $POD>
   ```
   </details>

3. **Two gatekeepers.** Delete the `filler` ReplicaSet, then apply
   [`exercises/big-request.yaml`](exercises/big-request.yaml). It is
   rejected. Change only its CPU values until it is accepted. Which
   admission plugin stopped you each time, and why?
   Solution: [`solutions/big-request.yaml`](solutions/big-request.yaml).

4. **Quota ≠ eviction.** With `big-request` running, lower `requests.cpu`
   in `04-resourcequota.yaml` to `100m` and re-apply it. What happens to the
   running pods? What happens to the next pod you create?
   <details><summary>Answer</summary>

   Nothing happens to running pods – `kubectl describe quota` simply shows
   `Used 180m / Hard 100m`. Every new pod that requests CPU is rejected
   until usage drops below the new limit. Restore `200m` afterwards.
   </details>

5. **Object-count quota.** Give `lab-namespaces-team-b` a quota that allows
   at most 2 Deployments and 10 Secrets, and prove it with `kubectl create deployment`.
   *Hint:* `count/<resource>.<group>`.
   Solution: [`solutions/team-b-object-quota.yaml`](solutions/team-b-object-quota.yaml).

## Cleanup

```bash
kubectl delete namespace lab-namespaces lab-namespaces-team-a lab-namespaces-team-b
# or, by label:
kubectl delete namespace -l app=namespaces
```

Namespace deletion is asynchronous: the namespace shows `Terminating` while
the namespace controller deletes everything inside it (the `kubernetes`
entry in `.spec.finalizers` holds it until that is done).

## Further reading

* [Namespaces](https://kubernetes.io/docs/concepts/overview/working-with-objects/namespaces/)
* [Labels and selectors](https://kubernetes.io/docs/concepts/overview/working-with-objects/labels/) and [annotations](https://kubernetes.io/docs/concepts/overview/working-with-objects/annotations/)
* [Recommended labels](https://kubernetes.io/docs/concepts/overview/working-with-objects/common-labels/) and [well-known labels, annotations and taints](https://kubernetes.io/docs/reference/labels-annotations-taints/)
* [Resource quotas](https://kubernetes.io/docs/concepts/policy/resource-quotas/) and [Limit ranges](https://kubernetes.io/docs/concepts/policy/limit-range/)
* [Owners and dependents](https://kubernetes.io/docs/concepts/overview/working-with-objects/owners-dependents/)
* [ReplicaSet – pod deletion cost](https://kubernetes.io/docs/concepts/workloads/controllers/replicaset/#pod-deletion-cost)
