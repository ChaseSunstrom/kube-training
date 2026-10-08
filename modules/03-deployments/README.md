# 03 – Deployments

## Goal

Run stateless apps the way production clusters do: declaratively, with
self-healing, scaling, zero-downtime rolling updates and fast rollbacks –
and know when *not* to roll.

## What you'll learn

* The ownership chain Deployment → ReplicaSet → Pod (`ownerReferences`, `pod-template-hash`)
* Scaling, and why it does not create a new revision
* `RollingUpdate` with `maxSurge` / `maxUnavailable`, watched live with `kubectl rollout status` and `-w`
* `kubernetes.io/change-cause`, `kubectl rollout history | undo | pause | resume | restart`
* A broken rollout that stalls safely, and how `progressDeadlineSeconds` reports it
* `minReadySeconds` and `revisionHistoryLimit`
* The `Recreate` strategy and when it is required (single writer on a ReadWriteOnce volume)
* Blue/green and canary releases built from nothing but labels and Services

## Concepts

### Who owns what

```
Deployment web                      you edit this
 └── ReplicaSet web-5f8495899        one per pod-template version (the hash of the template)
      ├── Pod web-5f8495899-dhn4l     ownerReferences → ReplicaSet web-5f8495899
      ├── Pod web-5f8495899-dsdkm
      └── ...
 └── ReplicaSet web-59d8fd8786       the next version, after you changed the template
```

* The **ReplicaSet controller** keeps N pods matching its selector alive (module 02).
* The **Deployment controller** manages ReplicaSets: when the pod template
  changes, it creates a new ReplicaSet and moves replicas from old to new.
  The pods get a `pod-template-hash` label so the ReplicaSets never select
  each other's pods.
* Every object records its owner in `metadata.ownerReferences`. The garbage
  collector uses that chain: delete a Deployment and its ReplicaSets and pods
  go too (unless you pass `--cascade=orphan`).

**What triggers a rollout?** Any change under `spec.template` (image, env,
args, resources, labels, annotations…). Changing `replicas`, `strategy` or
the Deployment's own metadata does **not**: no new ReplicaSet, no new revision.

### RollingUpdate vs Recreate

| | `RollingUpdate` (default) | `Recreate` |
|---|---|---|
| How | Start new pods, wait until they are available, stop old ones, repeat | Stop **all** old pods, then start the new ones |
| Downtime | none, if readiness probes are right | yes, from "old gone" until "new ready" |
| Old and new run at the same time | **yes** | never |
| Use for | stateless apps (almost everything) | apps that must never run two versions/copies at once: single-writer databases on a ReadWriteOnce volume, apps holding exclusive locks, incompatible schema migrations |

RollingUpdate knobs (absolute numbers or percentages of `replicas`):

* `maxSurge` – how many pods *above* `replicas` may exist during the rollout (default 25%, rounded up).
* `maxUnavailable` – how many pods *below* `replicas` may be unavailable (default 25%, rounded down).

With `replicas: 4, maxSurge: 1, maxUnavailable: 0` there are always ≥ 4
available pods and at most 5 in total: the rollout adds one new pod, waits
until it is **available**, removes one old pod, and repeats.

**Available** = Ready (readiness probe passes) **and** has stayed Ready for
`minReadySeconds`. Without a readiness probe, "Ready" means "the process
started" – and a rollout will happily replace good pods with broken ones.

### Rollout status and failure

A Deployment has two conditions worth knowing:

* `Available` – at least `replicas - maxUnavailable` pods are available.
* `Progressing` – `True` while the rollout makes progress; becomes
  `False` with reason **`ProgressDeadlineExceeded`** if nothing progresses for
  `progressDeadlineSeconds` (default 600). `kubectl rollout status` then exits
  non-zero – which is how CI/CD pipelines detect a failed deploy.

Kubernetes never rolls back on its own. A stalled rollout just stays where
it is (with `maxUnavailable: 0`, the old version keeps serving) until you fix
forward or run `kubectl rollout undo`.

### Releases with labels: blue/green and canary

A Service sends traffic to every *ready* pod matching its selector – it does
not care which Deployment the pods belong to. So:

* **Blue/green**: two full Deployments differing in one label (`color: blue|green`); the Service selects one color. Switching (and switching back) is a single selector change.
* **Canary**: a small Deployment of the new version with the same `app` label as the stable one; the Service selects only `app`, so the canary gets a share of traffic proportional to its replica count.

## Files

| File | What it demonstrates |
|---|---|
| [`00-namespace.yaml`](00-namespace.yaml) | The `lab-deployments` namespace |
| [`01-deployment.yaml`](01-deployment.yaml) | `web` v1: RollingUpdate (`maxSurge: 1`, `maxUnavailable: 0`), `minReadySeconds`, `progressDeadlineSeconds`, `revisionHistoryLimit`, change-cause |
| [`02-service.yaml`](02-service.yaml) | Service `web`, so you can send traffic during rollouts |
| [`03-client.yaml`](03-client.yaml) | A curl pod to send requests from inside the cluster |
| [`04-web-v2.yaml`](04-web-v2.yaml) | `web` v2 – a normal rolling update |
| [`05-web-v3-broken.yaml`](05-web-v3-broken.yaml) | `web` v3 – a non-existent image tag: a stalled rollout and `ProgressDeadlineExceeded` |
| [`06-recreate-pvc.yaml`](06-recreate-pvc.yaml) | A ReadWriteOnce PVC |
| [`07-recreate-deployment.yaml`](07-recreate-deployment.yaml) | redis with `strategy: Recreate` on that PVC |
| [`08-blue-green.yaml`](08-blue-green.yaml) | `shop-blue` and `shop-green` Deployments |
| [`09-blue-green-service.yaml`](09-blue-green-service.yaml) | Service `shop` that selects one color |
| [`10-canary.yaml`](10-canary.yaml) | `api-stable` (4 replicas) and `api-canary` (1 replica) |
| [`11-canary-service.yaml`](11-canary-service.yaml) | Service `api` over both tracks |
| [`solutions/`](solutions/) | Reference answers for the exercises |

> Walk through the steps in order. Files 01, 04 and 05 are three versions of
> the same Deployment, so `kubectl apply -f modules/03-deployments/` in one go
> ends on the broken v3 – exactly the situation step 6 teaches you to fix.

## Lab

### 1. Create the Deployment and follow the ownership chain

```bash
kubectl apply -f modules/03-deployments/00-namespace.yaml
kubectl apply -f modules/03-deployments/01-deployment.yaml \
              -f modules/03-deployments/02-service.yaml \
              -f modules/03-deployments/03-client.yaml
kubectl rollout status deployment/web -n lab-deployments
kubectl get deploy,rs,pods -n lab-deployments -l app=web
```

```
deployment "web" successfully rolled out
NAME                  READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/web   4/4     4            4           8s

NAME                            DESIRED   CURRENT   READY   AGE
replicaset.apps/web-5f8495899   4         4         4       8s

NAME                      READY   STATUS    RESTARTS   AGE
pod/web-5f8495899-dhn4l   1/1     Running   0          8s
pod/web-5f8495899-dsdkm   1/1     Running   0          8s
pod/web-5f8495899-qlhlv   1/1     Running   0          8s
pod/web-5f8495899-zcsvl   1/1     Running   0          8s
```

Names tell the story: `web` → `web-<template hash>` → `web-<template hash>-<random>`.
Follow the owner references up the chain:

```bash
POD=$(kubectl get pods -n lab-deployments -l app=web -o jsonpath='{.items[0].metadata.name}')
kubectl get pod $POD -n lab-deployments -o jsonpath='{.metadata.ownerReferences[0].kind}/{.metadata.ownerReferences[0].name}{"\n"}'
RS=$(kubectl get pod $POD -n lab-deployments -o jsonpath='{.metadata.ownerReferences[0].name}')
kubectl get rs $RS -n lab-deployments -o jsonpath='{.metadata.ownerReferences[0].kind}/{.metadata.ownerReferences[0].name}{"\n"}'
kubectl get pod $POD -n lab-deployments --show-labels
```

```
ReplicaSet/web-5f8495899
Deployment/web
NAME                  READY   STATUS    RESTARTS   AGE   LABELS
web-5f8495899-dhn4l   1/1     Running   0          20s   app=web,pod-template-hash=5f8495899
```

The app answers with its version (`Name:`) and the pod that served the request (`Hostname:`):

```bash
kubectl exec -n lab-deployments client -- curl -s http://web
```

```
Name: v1
Hostname: web-5f8495899-qlhlv
IP: 127.0.0.1
IP: 10.244.1.58
RemoteAddr: 10.244.3.67:58096
GET / HTTP/1.1
Host: web
...
```

### 2. Scale

```bash
kubectl scale deployment web -n lab-deployments --replicas=6
kubectl get rs -n lab-deployments -l app=web
kubectl rollout history deployment/web -n lab-deployments
```

The *same* ReplicaSet now has 6 pods and the history still has a single
revision – scaling is not a rollout. Two things to know:

* The next `kubectl apply -f 01-deployment.yaml` sets `replicas` back to 4,
  because the file says 4. If something else manages the replica count (an
  HPA, module 14), remove `replicas` from the file.
* Scaling down removes pods that are not ready / newest first (module 02 showed
  how `controller.kubernetes.io/pod-deletion-cost` changes that).

```bash
kubectl scale deployment web -n lab-deployments --replicas=4
```

### 3. A rolling update, watched live

Use three terminals:

```bash
# terminal 1: ReplicaSets shifting
kubectl get rs -n lab-deployments -l app=web -w

# terminal 2: continuous traffic, one request every 0.5s
kubectl exec -n lab-deployments client -- \
  sh -c 'while true; do echo "$(date +%T) $(curl -s -m 1 http://web | grep Name || echo FAILED)"; sleep 0.5; done'

# terminal 3: roll out v2
kubectl apply -f modules/03-deployments/04-web-v2.yaml
kubectl rollout status deployment/web -n lab-deployments
```

Terminal 3:

```
deployment.apps/web configured
Waiting for deployment "web" rollout to finish: 1 out of 4 new replicas have been updated...
Waiting for deployment "web" rollout to finish: 2 out of 4 new replicas have been updated...
Waiting for deployment "web" rollout to finish: 3 out of 4 new replicas have been updated...
Waiting for deployment "web" rollout to finish: 1 old replicas are pending termination...
deployment "web" successfully rolled out
```

Terminal 1 (trimmed) – read the `DESIRED` columns: new +1, wait, old −1, repeat.
Thanks to `minReadySeconds: 5` each step takes ~6 seconds, and the total never exceeds 5 pods:

```
NAME             DESIRED   CURRENT   READY   AGE
web-5f8495899    4         4         4       16s
web-59d8fd8786   1         1         0       0s
web-59d8fd8786   1         1         1       3s
web-5f8495899    3         4         4       26s     <- new pod available (ready 5s): scale old down
web-59d8fd8786   2         2         1       8s
web-59d8fd8786   2         2         2       12s
web-5f8495899    2         3         3       35s
web-59d8fd8786   3         3         3       18s
web-5f8495899    1         2         2       41s
web-59d8fd8786   4         4         4       24s
web-5f8495899    0         0         0       47s
```

Terminal 2: v1 and v2 answers mixed for ~25 seconds, then only v2 – and
(almost always) no `FAILED`:

```
10:44:59 Name: v1
10:45:00 Name: v2
10:45:00 Name: v1
...
10:45:21 Name: v2
```

An occasional single `FAILED` right as an old pod stops is the classic
shutdown race: the pod gets SIGTERM at the same moment it is removed from the
Service's EndpointSlice, and kube-proxy on every node needs a moment to stop
sending it traffic. `whoami` exits on SIGTERM immediately, so a request
already routed to it can fail. The usual fix is a short `preStop` delay
(`lifecycle.preStop.sleep`) so the pod keeps serving while it is taken out of
rotation — see graceful termination in [module 01](../01-pods/README.md).

During a rolling update **two versions serve traffic at the same time**.
Your app (and its API, database schema, cache format) must tolerate that –
or you need Recreate or blue/green.

The rollout history now has the change-cause of both revisions:

```bash
kubectl rollout history deployment/web -n lab-deployments
kubectl rollout history deployment/web -n lab-deployments --revision=2   # the full template of revision 2
```

```
REVISION  CHANGE-CAUSE
1         v1: initial release
2         v2: new greeting
```

The old ReplicaSet `web-5f8495899` is still there with 0 replicas – that *is*
revision 1. Up to `revisionHistoryLimit` (5) old ReplicaSets are kept.

### 4. Pause, batch several changes, resume

Every template change normally starts a rollout immediately. To make several
changes and roll them out **once**:

```bash
kubectl rollout pause deployment/web -n lab-deployments
kubectl set env deployment/web -n lab-deployments WHOAMI_NAME=v5
kubectl set resources deployment/web -n lab-deployments -c whoami --limits=cpu=150m,memory=48Mi
kubectl annotate deployment/web -n lab-deployments kubernetes.io/change-cause="v5: env + bigger limits" --overwrite
kubectl get rs -n lab-deployments -l app=web            # no new ReplicaSet yet
kubectl get deploy web -n lab-deployments -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}{"\n"}{end}'
```

```
Available=True MinimumReplicasAvailable
Progressing=Unknown DeploymentPaused
```

```bash
kubectl rollout resume deployment/web -n lab-deployments
kubectl rollout status deployment/web -n lab-deployments
kubectl rollout history deployment/web -n lab-deployments
```

```
REVISION  CHANGE-CAUSE
1         v1: initial release
2         v2: new greeting
3         v5: env + bigger limits
```

One new ReplicaSet, one new revision for both changes.

Now go back to the files, so the cluster matches Git again:

```bash
kubectl apply -f modules/03-deployments/04-web-v2.yaml
kubectl rollout status deployment/web -n lab-deployments
```

```
NAME             DESIRED   CURRENT   READY   AGE
web-59d8fd8786   4         4         4       80s
web-5f8495899    0         0         0       98s
web-7c84d79878   0         0         0       46s
REVISION  CHANGE-CAUSE
1         v1: initial release
3         v5: env + bigger limits
4         v2: new greeting
```

Kubernetes recognised the template: it scaled the **existing** v2 ReplicaSet
(`web-59d8fd8786`) back up instead of creating a new one, and revision 2
became revision 4. Same template, same hash, same ReplicaSet.

### 5. `kubectl rollout restart`

```bash
kubectl rollout restart deployment/web -n lab-deployments
```

"Restart all pods" (for example to pick up a changed ConfigMap, module 05)
is done by a rollout: kubectl adds the annotation
`kubectl.kubernetes.io/restartedAt` to the pod template, which changes it.
It is therefore as safe as any rolling update – and it adds a revision
(`5  v2: new greeting`: the change-cause annotation did not change, so it
repeats).

### 6. A broken rollout

```bash
kubectl apply -f modules/03-deployments/05-web-v3-broken.yaml
time kubectl rollout status deployment/web -n lab-deployments
```

```
Waiting for deployment "web" rollout to finish: 1 out of 4 new replicas have been updated...
error: deployment "web" exceeded its progress deadline

real	1m1.018s
```

`kubectl rollout status` exited with code 1 after `progressDeadlineSeconds: 60`. Look at the damage:

```bash
kubectl get deploy,rs,pods -n lab-deployments -l app=web
kubectl describe deployment web -n lab-deployments | sed -n '/^Conditions/,/^NewReplicaSet/p'
```

```
NAME                  READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/web   4/4     1            4           3m12s

NAME                             DESIRED   CURRENT   READY   AGE
replicaset.apps/web-59d8fd8786   0         0         0       2m54s
replicaset.apps/web-5f8495899    0         0         0       3m12s
replicaset.apps/web-6778b66746   4         4         4       94s
replicaset.apps/web-75bd749cdb   1         1         0       61s
replicaset.apps/web-7c84d79878   0         0         0       2m20s

NAME                       READY   STATUS         RESTARTS   AGE
pod/web-6778b66746-6klb2   1/1     Running        0          76s
pod/web-6778b66746-7q86t   1/1     Running        0          88s
pod/web-6778b66746-dqt8d   1/1     Running        0          82s
pod/web-6778b66746-kdf8g   1/1     Running        0          94s
pod/web-75bd749cdb-856rv   0/1     ErrImagePull   0          61s

Conditions:
  Type           Status  Reason
  ----           ------  ------
  Available      True    MinimumReplicasAvailable
  Progressing    False   ProgressDeadlineExceeded
OldReplicaSets:  web-5f8495899 (0/0 replicas created), web-59d8fd8786 (0/0 replicas created), web-7c84d79878 (0/0 replicas created), web-6778b66746 (4/4 replicas created)
NewReplicaSet:   web-75bd749cdb (1/1 replicas created)
```

(`web-6778b66746` is the v2 template plus the `restartedAt` annotation from
step 5. The new pod alternates between `ErrImagePull` and `ImagePullBackOff`.)

There is **no outage**: `maxUnavailable: 0` meant no old pod could be removed
before a new one was available, and none ever became available. All four v2
pods still serve (`kubectl exec -n lab-deployments client -- curl -s http://web | grep Name` → `Name: v2`).
`kubectl describe pod` on the new pod shows the cause: `Failed to pull image "traefik/whoami:v9.99-does-not-exist" ... not found`.

Roll back:

```bash
kubectl rollout undo deployment/web -n lab-deployments
kubectl rollout status deployment/web -n lab-deployments
kubectl rollout history deployment/web -n lab-deployments
```

```
Warning: resource deployments/web was previously managed with 'kubectl apply'. Rolling back will not update
the kubectl.kubernetes.io/last-applied-configuration annotation, which may cause unexpected behavior on
future 'kubectl apply' operations. Consider using 'kubectl apply' with your previous configuration file instead.
deployment.apps/web rolled back
deployment "web" successfully rolled out
REVISION  CHANGE-CAUSE
1         v1: initial release
3         v5: env + bigger limits
4         v2: new greeting
6         v3: broken image tag
7         v2: new greeting
```

`undo` returns to the *previous* revision (`--to-revision=N` picks another);
the rolled-back-to revision (5) gets a new number (7). It was instant because the
v2 ReplicaSet was still fully scaled. kubectl's warning is the important
lesson for real teams: `undo` changes the cluster but **not your YAML**. In a
Git-driven workflow you revert the commit and apply the old file instead –
here that would be `kubectl apply -f modules/03-deployments/04-web-v2.yaml`.

### 7. Recreate for a single writer on a ReadWriteOnce volume

```bash
kubectl apply -f modules/03-deployments/06-recreate-pvc.yaml
kubectl apply -f modules/03-deployments/07-recreate-deployment.yaml
kubectl rollout status deployment/cache -n lab-deployments
kubectl get pvc cache-data -n lab-deployments
kubectl exec -n lab-deployments deploy/cache -- redis-cli SET greeting "survived the rollout"
```

```
NAME         STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   ...
cache-data   Bound    pvc-ac1479a0-d080-45a0-86c3-199ce9b1a172   100Mi      RWO            standard       ...
OK
```

Watch a rollout with Recreate (`kubectl get pods -n lab-deployments -l app=cache -w`
in another terminal):

```bash
kubectl rollout restart deployment/cache -n lab-deployments
kubectl rollout status deployment/cache -n lab-deployments
kubectl exec -n lab-deployments deploy/cache -- redis-cli GET greeting
```

```
NAME                     READY   STATUS              RESTARTS   AGE
cache-7cb6686cff-5cnpv   1/1     Running             0          5s
cache-7cb6686cff-5cnpv   1/1     Terminating         0          7s
cache-7cb6686cff-5cnpv   0/1     Completed           0          8s
cache-fd8b8f69f-mrmjc    0/1     Pending             0          0s     <- created only after the old one stopped
cache-fd8b8f69f-mrmjc    0/1     ContainerCreating   0          0s
cache-fd8b8f69f-mrmjc    1/1     Running             0          1s
survived the rollout
```

The old pod stopped **before** the new one was created, so two redis
processes never shared the data directory. Why that matters:

* `ReadWriteOnce` means *one node*, not one pod. With kind's node-local
  storage, a RollingUpdate would start the second redis on the same node, on
  the same files, at the same time. Two writers on one data directory is how
  databases get corrupted.
* On cloud block storage (EBS, Persistent Disk, Azure Disk) the new pod may
  land on another node and hang in `ContainerCreating` with a
  `Multi-Attach error`, because the disk is still attached to the old node.
  With `maxUnavailable: 0` the old pod is never removed – the rollout deadlocks.

The price of Recreate is a short outage on every rollout. If you need two
*different* pods to share one RWO volume, or need strict ordering between
them, read [`scenarios/rwo-pvc-ordered-pods`](../../scenarios/rwo-pvc-ordered-pods/README.md).
For replicated databases, use a StatefulSet (module 07) – each replica gets its own volume.

### 8. Blue/green

```bash
kubectl apply -f modules/03-deployments/08-blue-green.yaml -f modules/03-deployments/09-blue-green-service.yaml
kubectl get pods -n lab-deployments -l app=shop -L color
kubectl exec -n lab-deployments client -- sh -c 'for i in 1 2 3 4; do curl -s http://shop | grep Name; done'
```

```
NAME                          READY   STATUS    RESTARTS   AGE   COLOR
shop-blue-f6767dc55-g4n2f     1/1     Running   0          4s    blue
shop-blue-f6767dc55-tdv8c     1/1     Running   0          4s    blue
shop-green-7c648c4cd6-8vqtx   1/1     Running   0          4s    green
shop-green-7c648c4cd6-9h96g   1/1     Running   0          4s    green
Name: shop blue (v1)
Name: shop blue (v1)
Name: shop blue (v1)
Name: shop blue (v1)
```

Green is running and could be tested directly (e.g. `kubectl port-forward deploy/shop-green 8080:80 -n lab-deployments`)
while every user still gets blue. Go live:

```bash
kubectl patch service shop -n lab-deployments -p '{"spec":{"selector":{"color":"green"}}}'
kubectl get service shop -n lab-deployments -o jsonpath='{.spec.selector}{"\n"}'
kubectl exec -n lab-deployments client -- sh -c 'for i in 1 2 3 4; do curl -s http://shop | grep Name; done'
```

```
{"app":"shop","color":"green"}
Name: shop green (v2)
Name: shop green (v2)
Name: shop green (v2)
Name: shop green (v2)
```

Instant, all at once, and rollback is the same patch with `blue`. ("Instant"
means within a second or so: the EndpointSlice controller updates the
Service's endpoints and kube-proxy on every node reprograms its rules.
Connections that are already open – HTTP keep-alive – stay on blue pods until
they close, so keep blue running for a while after the switch.) Once
you trust green, scale blue to 0 (or delete it) to get the capacity back.

### 9. Canary

```bash
kubectl apply -f modules/03-deployments/10-canary.yaml -f modules/03-deployments/11-canary-service.yaml
kubectl get pods -n lab-deployments -l app=api -L track
kubectl exec -n lab-deployments client -- \
  sh -c 'for i in $(seq 100); do curl -s http://api | grep Name; done' | sort | uniq -c
```

```
NAME                          READY   STATUS    RESTARTS   AGE   TRACK
api-canary-657f967c64-lrng8   1/1     Running   0          5s    canary
api-stable-9696655f9-5n757    1/1     Running   0          5s    stable
...
     26 Name: api canary (v2)
     74 Name: api stable (v1)
```

1 of 5 pods → roughly 20 % of requests (the Service picks a backend at
random per connection, so expect some variation). Watch the canary's logs
and error rate; if it misbehaves, `kubectl scale deployment api-canary -n lab-deployments --replicas=0`
and only a fifth of requests were ever affected. If it is good, promote it
(exercise 5).

## Exercises

1. **Imperative rollout + targeted rollback.** Without editing files, change
   `web`'s `WHOAMI_NAME` to `v7` with `kubectl set env`, record a
   change-cause with `kubectl annotate`, then roll back to the **most recent**
   revision whose change-cause is `v2: new greeting` using `--to-revision`
   (after the lab, more than one revision carries that text — the history
   lists the latest one last).
   *Hint:* `kubectl rollout history deployment/web -n lab-deployments` first; revision numbers change on every undo.

2. **Trade-offs of the rollout knobs.** Predict, then observe with
   `kubectl get rs -w`, the maximum number of pods and the minimum number of
   available pods during a rollout of `web` (4 replicas) with
   (a) `maxSurge: 0, maxUnavailable: 1` and (b) `maxSurge: 100%, maxUnavailable: 0`.
   Which one needs spare cluster capacity? Which one is faster?
   Solution for (b): [`solutions/web-fast-rollout.yaml`](solutions/web-fast-rollout.yaml).

3. **Cascading deletes.** (a) Delete the *active* ReplicaSet of `web`. What
   does the Deployment do, and do clients notice? (b) Delete the Deployment
   with `--cascade=orphan`, look at the ReplicaSets and pods, then re-apply
   `04-web-v2.yaml`. Do the pods restart?
   <details><summary>Answer</summary>

   (a) The pods go with the ReplicaSet; the Deployment immediately creates a
   ReplicaSet with the **same name** (same template hash) and new pods – a
   short outage, because nothing protected availability. Never "fix" things by
   deleting ReplicaSets. (b) The ReplicaSets and pods keep running, with no
   `ownerReferences`. The re-created Deployment **adopts** every ReplicaSet its
   selector matches. If one of them has exactly the same template hash as the
   file, it becomes the current one and no pod restarts (compare the AGE
   column). But if the running pods came from `kubectl rollout restart`
   (step 5) or a rollback to such a revision, their template also carries the
   `restartedAt` annotation, which the file does not have: the new Deployment
   then rolls over (a normal rolling update, new pods) to the ReplicaSet of
   the plain v2 template – `web-59d8fd8786`, if it is still in the history.
   </details>

4. **History limit.** Set `revisionHistoryLimit: 1` on `web` (patch or edit),
   then list the ReplicaSets and the rollout history. What can you no longer do?
   <details><summary>Answer</summary>

   Only the current and one old ReplicaSet remain; the others are deleted by
   the Deployment controller. `kubectl rollout undo --to-revision=1` now fails with
   `unable to find specified revision 1 in history`. `0` would keep no history at all.
   </details>

5. **Promote the canary.** Make all `api` traffic go to the v2 version with
   zero downtime, and get rid of the canary pod. Verify with 20 requests.
   Solution: [`solutions/canary-promoted.yaml`](solutions/canary-promoted.yaml).

6. **Immutable selector.** Try to change `web`'s selector to `app: web2`
   (and the template labels with it). Why is it rejected, and how do you
   make such a change in practice?
   *Hint:* `kubectl patch deployment web -n lab-deployments --type=merge -p '{"spec":{"selector":{"matchLabels":{"app":"web2"}},"template":{"metadata":{"labels":{"app":"web2"}}}}}'`
   <details><summary>Answer</summary>

   `spec.selector: Invalid value: ... field is immutable` (for `apps/v1`).
   Changing it would orphan every existing ReplicaSet and pod. Create a *new*
   Deployment with the new selector (a different name, or delete and
   re-create – accepting the downtime), move the Service over, then delete
   the old one: blue/green, in fact.
   </details>

## Cleanup

```bash
kubectl delete namespace lab-deployments
```

This also deletes the PVC `cache-data`; local-path's reclaim policy is
`Delete`, so its PersistentVolume and the data on the node are removed too.

## Further reading

* [Deployments](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/) (strategies, rollover, pausing, failed deployments)
* [ReplicaSet](https://kubernetes.io/docs/concepts/workloads/controllers/replicaset/)
* [Garbage collection and owner references](https://kubernetes.io/docs/concepts/architecture/garbage-collection/)
* [`kubectl rollout`](https://kubernetes.io/docs/reference/kubectl/generated/kubectl_rollout/)
* [Managing workloads – canary deployments](https://kubernetes.io/docs/concepts/workloads/management/#canary-deployments)
* [Persistent volume access modes](https://kubernetes.io/docs/concepts/storage/persistent-volumes/#access-modes)
