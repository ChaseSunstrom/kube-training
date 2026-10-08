# Module 07 – StatefulSets

## Goal

Run pods that need a stable identity (a fixed name, a fixed DNS entry and
their own persistent disk) and control the order in which they are created,
updated and removed.

## What you'll learn

* Headless Services and the per-pod DNS names they create
  (`web-0.web.lab-statefulsets.svc.cluster.local`).
* `volumeClaimTemplates`: one PVC per pod that follows the pod's identity
  through deletion and rescheduling.
* `podManagementPolicy`: `OrderedReady` vs `Parallel`, and the scale-down
  order.
* Update strategies: `RollingUpdate` with `partition` (canary), `maxUnavailable`,
  and `OnDelete`.
* `persistentVolumeClaimRetentionPolicy` (`whenDeleted` / `whenScaled`),
  `.spec.ordinals.start` and the `apps.kubernetes.io/pod-index` label.
* When a StatefulSet is the right tool, when a Deployment + PVC is enough,
  and why real databases are run by operators.

## Concepts

### What a StatefulSet adds over a Deployment

A Deployment treats its pods as interchangeable cattle: random names, one
shared pod template, created and killed in any order. A StatefulSet gives
each pod a **sticky identity** made of three parts:

```
StatefulSet "web" (serviceName: web, replicas: 3)
│
├── web-0 ── PVC www-web-0 ── PV pvc-…   DNS: web-0.web.lab-statefulsets.svc.cluster.local
├── web-1 ── PVC www-web-1 ── PV pvc-…   DNS: web-1.web.lab-statefulsets.svc.cluster.local
└── web-2 ── PVC www-web-2 ── PV pvc-…   DNS: web-2.web.lab-statefulsets.svc.cluster.local

Service "web" (clusterIP: None, headless)
  web.lab-statefulsets.svc.cluster.local → A records of all READY pods
```

| Part of the identity | How it works |
|---|---|
| **Ordinal name** | Pods are `<sts-name>-<ordinal>`, ordinals `0 … replicas-1` (or from `.spec.ordinals.start`). A deleted `web-1` is replaced by a new `web-1`. |
| **Network identity** | The pod's `hostname` is its name and its `subdomain` is `serviceName`. A **headless** Service of that name gives each pod a DNS record. The IP still changes when the pod is recreated. The *name* is what's stable. |
| **Storage** | Each `volumeClaimTemplates` entry creates a PVC named `<template>-<pod>` (`www-web-1`). The new `web-1` mounts the same PVC, so it gets the same data. |

Two labels let you select individual members, for example to put a Service in
front of just one of them:

* `statefulset.kubernetes.io/pod-name: web-1`
* `apps.kubernetes.io/pod-index: "1"`

(Indexed Jobs have a similar label of their own,
`batch.kubernetes.io/job-completion-index`; see
[module 08](../08-jobs-cronjobs/README.md).)

### Ordering: podManagementPolicy

| | `OrderedReady` (default) | `Parallel` |
|---|---|---|
| Scale up | `web-0`, then `web-1` once `web-0` is **Running and Ready**, then `web-2` … | all at once |
| Scale down | highest ordinal first, one at a time, each fully terminated before the next | all at once |
| Rolling updates | one at a time, highest ordinal first | same (unless `maxUnavailable` > 1, see below) |
| Use for | clustered software where member N joins via member 0 (classic primary/replica set-ups, ZooKeeper, etcd) | members that discover each other independently; faster scaling |

### Update strategies

* **`RollingUpdate`** (default): pods are replaced from the highest ordinal to
  the lowest. The controller waits for each new pod to be Running and Ready
  before it touches the next one.
  * **`partition: N`**: only pods with ordinal **≥ N** are updated. The rest
    stay on the old revision, even if they are deleted and recreated. Set
    `partition: 2` on a 3-replica set to canary `web-2`, then lower it to roll
    out further. Setting it to `replicas` pauses updates completely.
  * **`maxUnavailable`**: how many pods may be down at once during the update
    (default 1). Beta and enabled by default in Kubernetes 1.37. In practice it
    only speeds things up with `podManagementPolicy: Parallel`. With
    `OrderedReady`, pods still become ready one at a time.
* **`OnDelete`**: the controller never replaces running pods by itself. A pod
  picks up the new template only when you delete it. Use this when an operator
  or a human must decide exactly when each member restarts.

The StatefulSet records each template version as a `ControllerRevision`.
`.status.currentRevision` and `.status.updateRevision` (and the
`controller-revision-hash` label on each pod) tell you who is on which
version. `kubectl rollout status|history|undo` work as they do for
Deployments.

### What happens to the PVCs?

By default, **nothing**. PVCs created from `volumeClaimTemplates` outlive
scale-downs and even the deletion of the StatefulSet, so data is never lost by
accident. `persistentVolumeClaimRetentionPolicy` changes that:

| Field | `Retain` (default) | `Delete` |
|---|---|---|
| `whenScaled` | scaling 3 → 1 keeps `www-web-1` and `www-web-2`. Scaling back up re-attaches them, old data included. | the PVCs of removed pods are deleted |
| `whenDeleted` | deleting the StatefulSet keeps all PVCs | all PVCs are deleted with the StatefulSet |

Deleting a PVC with `Delete` triggers the StorageClass reclaim policy, which
usually deletes the disk too ([module 06](../06-storage/README.md)).

### Gotchas worth knowing

* **Deleting a StatefulSet does not terminate pods in order.** If order
  matters, `kubectl scale sts/web --replicas=0` first, wait, then delete.
* **Never force-delete a StatefulSet pod casually**
  (`--force --grace-period=0`). The controller may start a replacement `web-1`
  while the old one is still running on an unreachable node: two pods with
  the same identity writing to the same data.
* **A bad template can wedge an `OrderedReady` rollout.** If the new `web-2`
  never becomes Ready, the rollout stops there. Rolling back the template is
  *not enough*: you must also delete the stuck pod (exercise 3).
* `volumeClaimTemplates`, `selector` and `serviceName` can't be edited after
  creation. To grow the volumes, resize each PVC directly (if the
  StorageClass allows expansion). To change the template itself, recreate the
  StatefulSet with `kubectl delete sts web --cascade=orphan`, which keeps the
  pods and PVCs.

### StatefulSet or Deployment + PVC?

| Need | Use |
|---|---|
| Stateless app, or all replicas share one RWX volume | **Deployment** |
| Exactly one replica with one RWO volume (a small app's SQLite or uploads dir) | **Deployment** + PVC + `strategy: Recreate` is fine, or a 1-replica StatefulSet |
| Each replica needs **its own** volume | **StatefulSet** (a Deployment can't template per-pod PVCs) |
| Replicas must be addressable individually (`db-0`, `db-1`) or know their ordinal | **StatefulSet** |
| Members must start/stop in a defined order | **StatefulSet** (`OrderedReady`) |
| Two *different* pods sharing one RWO volume in a specific order | see [`../../scenarios/rwo-pvc-ordered-pods/README.md`](../../scenarios/rwo-pvc-ordered-pods/README.md) |

### Why operators exist for real databases

A StatefulSet gives you identity, storage and ordering. It knows nothing about
the software inside. For PostgreSQL, MySQL, Kafka or Redis in production you
also need:

* bootstrapping replication ("`db-0` is primary, the others replicate from
  it"),
* **failover**: promote a replica when the primary dies, and re-point clients,
* backups, point-in-time recovery, restores,
* safe version upgrades (replicas first, then a switchover),
* reconfiguration, scaling with data rebalancing, certificate rotation.

An **operator** is a controller plus CRDs that encodes this knowledge. You
write `kind: Cluster, instances: 3` and it manages StatefulSets or pods, PVCs,
Services and Secrets for you. Examples: CloudNativePG and Zalando's
postgres-operator (PostgreSQL), Strimzi (Kafka), Percona operators (MySQL,
MongoDB). Rule of thumb: run a database on a bare StatefulSet to learn, use an
operator (or a managed service) for anything you can't afford to lose.

## Files

| File | What it demonstrates |
|---|---|
| [`00-namespace.yaml`](00-namespace.yaml) | the `lab-statefulsets` namespace |
| [`01-headless-service.yaml`](01-headless-service.yaml) | the headless governing Service `web` |
| [`02-statefulset.yaml`](02-statefulset.yaml) | StatefulSet `web`: nginx, per-pod PVCs, `OrderedReady`, `RollingUpdate` + `partition`, retention policy |
| [`03-client.yaml`](03-client.yaml) | busybox client for DNS and HTTP tests |
| [`04-statefulset-parallel.yaml`](04-statefulset-parallel.yaml) | `podManagementPolicy: Parallel` |
| [`05-statefulset-ordinals.yaml`](05-statefulset-ordinals.yaml) | `ordinals.start: 1`, `pod-index` via the Downward API, PVC retention `Delete` |
| [`solutions/`](solutions/) | reference answers for the exercises |

## Lab

```bash
cd modules/07-statefulsets
kubectl apply -f 00-namespace.yaml -f 01-headless-service.yaml
```

### 1. Create the StatefulSet and watch the order

Open a second terminal and watch:

```bash
kubectl get pods -n lab-statefulsets -l app=web -w
```

In the first terminal:

```bash
kubectl apply -f 02-statefulset.yaml
kubectl rollout status sts/web -n lab-statefulsets
```

The watch shows strictly one pod at a time (trimmed):

```
NAME    READY   STATUS            RESTARTS   AGE
web-0   0/1     Pending           0          0s
web-0   0/1     Init:0/1          0          6s
web-0   0/1     Running           0          8s
web-0   1/1     Running           0          11s
web-1   0/1     Pending           0          0s
web-1   0/1     Init:0/1          0          5s
web-1   0/1     Running           0          7s
web-1   1/1     Running           0          10s
web-2   0/1     Pending           0          0s
...
web-2   1/1     Running           0          9s
```

`web-1` isn't even *created* until `web-0` is `1/1` Ready. Each pod spends a
few seconds in `Pending` while local-path provisions its volume (see
`WaitForFirstConsumer` in [module 06](../06-storage/README.md)).

### 2. Look at the identities

```bash
kubectl get pods,pvc -n lab-statefulsets -o wide
kubectl get pods -n lab-statefulsets -l app=web \
  -L apps.kubernetes.io/pod-index,statefulset.kubernetes.io/pod-name,controller-revision-hash
```

```
NAME        READY   STATUS    RESTARTS   AGE   IP           NODE
pod/web-0   1/1     Running   0          30s   10.244.3.7   kube-training-worker
pod/web-1   1/1     Running   0          19s   10.244.1.6   kube-training-worker2
pod/web-2   1/1     Running   0          9s    10.244.3.9   kube-training-worker

NAME                              STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS
persistentvolumeclaim/www-web-0   Bound    pvc-674eeeb9-012f-4c6a-84ab-af07fb28960e   100Mi      RWO            standard
persistentvolumeclaim/www-web-1   Bound    pvc-0cb3ec9f-6820-45c8-af8c-9aeb92031b5a   100Mi      RWO            standard
persistentvolumeclaim/www-web-2   Bound    pvc-bee28ea6-a6a0-4d9e-ad4e-8822d7e40415   100Mi      RWO            standard

NAME    READY   STATUS    RESTARTS   AGE   POD-INDEX   POD-NAME   CONTROLLER-REVISION-HASH
web-0   1/1     Running   0          30s   0           web-0      web-7f59fd7559
web-1   1/1     Running   0          19s   1           web-1      web-7f59fd7559
web-2   1/1     Running   0          9s    2           web-2      web-7f59fd7559
```

### 3. Stable network identity

```bash
kubectl apply -f 03-client.yaml
kubectl wait -n lab-statefulsets --for=condition=Ready pod/client

# The headless Service name returns every ready pod:
kubectl exec -n lab-statefulsets client -- nslookup web.lab-statefulsets.svc.cluster.local
# Each pod has its own name:
kubectl exec -n lab-statefulsets client -- nslookup web-0.web.lab-statefulsets.svc.cluster.local
```

```
Name:	web.lab-statefulsets.svc.cluster.local
Address: 10.244.3.9
Name:	web.lab-statefulsets.svc.cluster.local
Address: 10.244.1.6
Name:	web.lab-statefulsets.svc.cluster.local
Address: 10.244.3.7

Name:	web-0.web.lab-statefulsets.svc.cluster.local
Address: 10.244.3.7
```

There's no ClusterIP: the Service name resolves directly to pod IPs. Inside
the namespace the short form `web-1.web` works too, *except* with busybox's
`nslookup`, which ignores the search domains in `/etc/resolv.conf` and answers
`NXDOMAIN`. Normal programs (and busybox `wget`) use the search path:

```bash
for i in 0 1 2; do kubectl exec -n lab-statefulsets client -- wget -qO- http://web-$i.web; done
kubectl exec -n lab-statefulsets web-0 -c nginx -- hostname -f
```

```
page created by web-0 at 10:38:49
page created by web-1 at 10:38:59
page created by web-2 at 10:39:08
web-0.web.lab-statefulsets.svc.cluster.local
```

### 4. Stable storage: delete a pod

```bash
kubectl get pod web-1 -n lab-statefulsets -o custom-columns=NAME:.metadata.name,UID:.metadata.uid,IP:.status.podIP,NODE:.spec.nodeName
kubectl delete pod web-1 -n lab-statefulsets
kubectl wait -n lab-statefulsets --for=condition=Ready pod/web-1
kubectl get pod web-1 -n lab-statefulsets -o custom-columns=NAME:.metadata.name,UID:.metadata.uid,IP:.status.podIP,NODE:.spec.nodeName
kubectl exec -n lab-statefulsets client -- wget -qO- http://web-1.web
```

```
NAME    UID                                    IP           NODE
web-1   36652a4a-4353-448d-aa4f-b1c0fff0c618   10.244.1.6   kube-training-worker2
pod "web-1" deleted
pod/web-1 condition met
NAME    UID                                    IP           NODE
web-1   804c9eb0-c4f3-4ba8-aa75-10795d963eb8   10.244.1.9   kube-training-worker2
page created by web-1 at 10:38:59
```

New UID, new IP, **same name, same PVC, same data**, and the DNS name
`web-1.web` now points to the new IP. It landed on the same node because the
local-path PV has node affinity. With network storage it could move to any
node and take its disk along.

### 5. Scale down and up

Keep the watch from step 1 running (or restart it), then:

```bash
kubectl scale sts web -n lab-statefulsets --replicas=1
```

```
web-2   1/1     Terminating   0          45s
web-2   0/1     Completed     0          46s
web-1   1/1     Terminating   0          16s
web-1   0/1     Completed     0          17s
```

Highest ordinal first, one at a time. The PVCs are all still there:

```bash
kubectl get pvc -n lab-statefulsets
```

```
NAME        STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS
www-web-0   Bound    pvc-674eeeb9-012f-4c6a-84ab-af07fb28960e   100Mi      RWO            standard
www-web-1   Bound    pvc-0cb3ec9f-6820-45c8-af8c-9aeb92031b5a   100Mi      RWO            standard
www-web-2   Bound    pvc-bee28ea6-a6a0-4d9e-ad4e-8822d7e40415   100Mi      RWO            standard
```

Scale back up. `web-1` and `web-2` find their old volumes, so the pages still
show the original creation times:

```bash
kubectl scale sts web -n lab-statefulsets --replicas=3
kubectl rollout status sts/web -n lab-statefulsets
for i in 0 1 2; do kubectl exec -n lab-statefulsets client -- wget -qO- http://web-$i.web; done
```

```
page created by web-0 at 10:38:49
page created by web-1 at 10:38:59
page created by web-2 at 10:39:08
```

### 6. Canary an update with `partition`

Allow updates only for ordinals ≥ 2, then change the template:

```bash
kubectl patch sts web -n lab-statefulsets -p '{"spec":{"updateStrategy":{"rollingUpdate":{"partition":2}}}}'
kubectl set env sts/web -n lab-statefulsets -c nginx APP_VERSION=v2
kubectl rollout status sts/web -n lab-statefulsets
kubectl get pods -n lab-statefulsets -l app=web -L controller-revision-hash
for i in 0 1 2; do echo -n "web-$i: "; kubectl exec -n lab-statefulsets web-$i -c nginx -- printenv APP_VERSION; done
```

```
partitioned roll out complete: 1 new pods have been updated...
NAME    READY   STATUS    RESTARTS   AGE   CONTROLLER-REVISION-HASH
web-0   1/1     Running   0          95s   web-7f59fd7559
web-1   1/1     Running   0          26s   web-7f59fd7559
web-2   1/1     Running   0          7s    web-6bbd946bd6
web-0: v1
web-1: v1
web-2: v2
```

Only `web-2` runs the new revision. If you're happy with the canary, roll
out to everyone and watch the order (`web-1`, then `web-0`):

```bash
kubectl patch sts web -n lab-statefulsets -p '{"spec":{"updateStrategy":{"rollingUpdate":{"partition":0}}}}'
kubectl rollout status sts/web -n lab-statefulsets
kubectl get pods -n lab-statefulsets -l app=web -L controller-revision-hash
```

```
NAME    READY   STATUS    RESTARTS   AGE   CONTROLLER-REVISION-HASH
web-0   1/1     Running   0          6s    web-6bbd946bd6
web-1   1/1     Running   0          12s   web-6bbd946bd6
web-2   1/1     Running   0          20s   web-6bbd946bd6
```

### 7. `OnDelete`: you decide when each pod restarts

```bash
kubectl patch sts web -n lab-statefulsets --type merge \
  -p '{"spec":{"updateStrategy":{"type":"OnDelete","rollingUpdate":null}}}'
kubectl set env sts/web -n lab-statefulsets -c nginx APP_VERSION=v3
kubectl get pods -n lab-statefulsets -l app=web -L controller-revision-hash   # nothing restarts
kubectl delete pod web-1 -n lab-statefulsets
kubectl wait -n lab-statefulsets --for=condition=Ready pod/web-1
for i in 0 1 2; do echo -n "web-$i: "; kubectl exec -n lab-statefulsets web-$i -c nginx -- printenv APP_VERSION; done
```

```
web-0: v2
web-1: v3
web-2: v2
```

Only the pod you deleted picked up `v3`. (`kubectl rollout status` refuses
to work with `OnDelete`: there's no rollout to follow.) Switch back. The
remaining pods are updated straight away:

```bash
kubectl patch sts web -n lab-statefulsets --type merge \
  -p '{"spec":{"updateStrategy":{"type":"RollingUpdate","rollingUpdate":{"partition":0}}}}'
kubectl rollout status sts/web -n lab-statefulsets
```

### 8. `Parallel` pod management

```bash
kubectl get pods -n lab-statefulsets -l app=fast -w      # second terminal
kubectl apply -f 04-statefulset-parallel.yaml
```

```
NAME     READY   STATUS              RESTARTS   AGE
fast-0   0/1     Pending             0          0s
fast-2   0/1     Pending             0          0s
fast-1   0/1     Pending             0          0s
fast-0   0/1     ContainerCreating   0          0s
fast-1   0/1     ContainerCreating   0          0s
fast-2   0/1     ContainerCreating   0          0s
...
fast-0   1/1     Running             0          6s
fast-1   1/1     Running             0          6s
fast-2   1/1     Running             0          7s
```

All three are created together, in no particular order, without waiting for
each other. Scaling down is parallel too:

```bash
kubectl scale sts fast -n lab-statefulsets --replicas=1
```

```
fast-2   1/1     Terminating         0          7s
fast-1   1/1     Terminating         0          7s
```

### 9. Start ordinal, pod-index and automatic PVC cleanup

```bash
kubectl apply -f 05-statefulset-ordinals.yaml
kubectl rollout status sts/shard -n lab-statefulsets
kubectl get pods,pvc -n lab-statefulsets -l app=shard -L apps.kubernetes.io/pod-index
kubectl logs -n lab-statefulsets shard-1
```

```
NAME          READY   STATUS    RESTARTS   AGE   POD-INDEX
pod/shard-1   1/1     Running   0          21s   1
pod/shard-2   1/1     Running   0          14s   2
pod/shard-3   1/1     Running   0          7s    3

NAME                                 STATUS   VOLUME          ...
persistentvolumeclaim/data-shard-1   Bound    pvc-070e7d57-…
persistentvolumeclaim/data-shard-2   Bound    pvc-e7054f89-…
persistentvolumeclaim/data-shard-3   Bound    pvc-30308efb-…
I am shard 1
```

Numbering starts at 1, and the pod read its own index from the
`apps.kubernetes.io/pod-index` label via the Downward API. Now scale down:
with `whenScaled: Delete`, the PVCs go too:

```bash
kubectl get pvc data-shard-2 -n lab-statefulsets -o jsonpath='{.metadata.ownerReferences[*].kind}'; echo
kubectl scale sts shard -n lab-statefulsets --replicas=1
kubectl get pods,pvc -n lab-statefulsets -l app=shard     # give it a few seconds
```

```
StatefulSet
NAME          READY   STATUS    RESTARTS   AGE
pod/shard-1   1/1     Running   0          26s

NAME                                 STATUS   VOLUME          ...
persistentvolumeclaim/data-shard-1   Bound    pvc-070e7d57-…
```

And with `whenDeleted: Delete`, deleting the StatefulSet takes the last PVC
with it, through the ownerReference you just printed:

```bash
kubectl delete sts shard -n lab-statefulsets
kubectl get pvc -n lab-statefulsets -l app=shard          # No resources found
```

Compare with `web`, which uses the default `Retain`: its PVCs survived the
scale-down in step 5.

## Exercises

1. **DNS detective.** Scale `web` to 2. What does
   `nslookup web-2.web.lab-statefulsets.svc.cluster.local` return now, and
   how many addresses does `web.lab-statefulsets.svc.cluster.local` return?
   What would change if `web-1` were running but not Ready?
   *Hint:* headless Services publish only Ready endpoints unless
   `publishNotReadyAddresses: true`. Look at
   `kubectl get endpointslices -n lab-statefulsets -l kubernetes.io/service-name=web -o yaml`.

2. **A Service for one member.** Create a normal ClusterIP Service
   `web-0-only` that always sends traffic to `web-0`.
   *Hint:* the identity labels from Concepts. Solution:
   [`solutions/02-web-0-service.yaml`](solutions/02-web-0-service.yaml). Test
   with `kubectl exec -n lab-statefulsets client -- wget -qO- http://web-0-only`
   (give kube-proxy a second after creating the Service).

3. **The wedged rollout.** Break the readiness probe:
   `kubectl patch sts web -n lab-statefulsets --type json -p '[{"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/path","value":"/nope"}]'`.
   Watch `web-2` get stuck at `0/1`. Then run `kubectl rollout undo sts/web -n lab-statefulsets`.
   Does the rollout recover on its own? What do you have to do?
   *Hint:* here, after the undo, `web-2` stayed on the broken revision and
   `rollout status` still timed out. `kubectl delete pod web-2` lets the
   controller recreate it from the good revision. (Kubernetes docs: "Forced
   rollback".)

4. **Redis that remembers.** Run a single Redis (`redis:7.4-alpine`) as a
   StatefulSet with a 100Mi volume. Write a key, delete the pod, read the key.
   What does Redis need to be told so that the data really is on the volume?
   *Hint:* `--appendonly yes`; the image's data directory is `/data`.
   Solution: [`solutions/04-redis-statefulset.yaml`](solutions/04-redis-statefulset.yaml).

5. **Faster updates.** Make `fast` (4 replicas) update two pods at a time.
   Why would the same setting do little for `web`?
   *Hint:* `kubectl patch sts fast -n lab-statefulsets --type merge -p '{"spec":{"replicas":4,"updateStrategy":{"rollingUpdate":{"maxUnavailable":2}}}}'`,
   then `kubectl set env sts/fast -n lab-statefulsets X=1` with a watch running.
   You'll see `fast-3` and `fast-2` terminate together, then `fast-1` and
   `fast-0`. `web` uses `OrderedReady`.

6. **Recreate without losing data.** Change `web`'s volume size in
   `02-statefulset.yaml` to `200Mi` and `kubectl apply` it. Read the error.
   Recreate the StatefulSet *without* deleting pods or data, so that the new
   template is accepted. Do the existing PVCs grow? Why not?
   *Hint:* the error ends in `spec.volumeClaimTemplates: Invalid value: ...:
   field is immutable`. Run
   `kubectl delete sts web -n lab-statefulsets --cascade=orphan`, then apply
   again. The running pods are adopted by the new StatefulSet (and rolled,
   because the file's `APP_VERSION` differs from what you set in step 7).
   Existing PVCs keep 100Mi: templates only apply to *new* PVCs, and local-path
   can't expand anyway.

## Cleanup

```bash
kubectl delete namespace lab-statefulsets
```

This deletes the remaining PVCs (`www-web-*`, `data-redis-0` …). Their PVs use
reclaim policy `Delete`, so the volumes are removed too. No cluster-scoped
objects are created in this module.

## Further reading

* [StatefulSets](https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/)
* [StatefulSet basics tutorial](https://kubernetes.io/docs/tutorials/stateful-application/basic-stateful-set/)
* [Run a replicated stateful application](https://kubernetes.io/docs/tasks/run-application/run-replicated-stateful-application/)
* [Force delete StatefulSet pods](https://kubernetes.io/docs/tasks/run-application/force-delete-stateful-set-pod/)
* [DNS for Services and Pods](https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/)
* [Operator pattern](https://kubernetes.io/docs/concepts/extend-kubernetes/operator/)
