# Module 10 – Scheduling

## Goal

Control **which node** each pod runs on – and understand exactly why the
scheduler placed (or refused to place) a pod.

## What you'll learn

* How the scheduler decides: filter → score → bind
* `nodeSelector` and node affinity (required vs preferred, weights, operators)
* Pod affinity / anti-affinity and what `topologyKey` means
  (`kubernetes.io/hostname` vs `training/zone`)
* The **"first pod of a self-affine group"** rule – the trick that lets two
  workloads share a node (and a ReadWriteOnce volume) without naming the node
* Taints and tolerations: `NoSchedule`, `PreferNoSchedule`, `NoExecute` +
  `tolerationSeconds`
* `topologySpreadConstraints` (`maxSkew`, `whenUnsatisfiable`,
  `matchLabelKeys`, `nodeTaintsPolicy`)
* PriorityClasses and preemption
* Reading `FailedScheduling` events like a pro
* Scheduling gates (`schedulingGates`) and manual scheduling with `nodeName`
  (and why to avoid it)

## Concepts

### How a pod gets a node

```
kubectl apply ──> API server ──> pod with spec.nodeName empty
                                   │
                    ┌──────────────▼──────────────┐
                    │ kube-scheduler              │
                    │  queue (sorted by priority) │
                    │  1. FILTER  nodes that can't run the pod are dropped
                    │     (resources, nodeSelector/affinity, taints,
                    │      pod (anti-)affinity, topology spread, ports...)
                    │  2. SCORE   remaining nodes get points
                    │     (preferred affinity, spreading, balance, images...)
                    │  3. BIND    write spec.nodeName = best node
                    └──────────────┬──────────────┘
                                   ▼
                     kubelet on that node starts the containers
```

If **no** node survives the filter, the pod stays `Pending`, the scheduler
records a `FailedScheduling` event and (if the pod has a priority) tries
**preemption**. It retries automatically whenever something relevant changes in
the cluster (a node is added, a pod is deleted, a taint is removed...) and at
the latest every 5 minutes.

### The tools at a glance

| Mechanism | Looks at | Hard / soft | Typical use |
|---|---|---|---|
| `nodeSelector` | node labels | hard | "only on SSD nodes" |
| node affinity | node labels (with operators) | `required…` = hard, `preferred…` = soft (weights 1–100) | "zone-a or zone-b, preferably zone-b" |
| pod affinity | labels of pods **already on** nodes in a topology domain | hard / soft | co-locate cache with app |
| pod anti-affinity | same | hard / soft | one replica per node |
| taints + tolerations | node taints vs pod tolerations | `NoSchedule` hard, `PreferNoSchedule` soft, `NoExecute` hard + evicts | dedicated nodes, maintenance, node problems |
| topology spread | count of matching pods per domain | `DoNotSchedule` hard, `ScheduleAnyway` soft | even spread over zones/nodes |
| priority + preemption | `spec.priority` | — | important pods evict unimportant ones |
| scheduling gates | `spec.schedulingGates` | hard, until removed | "don't even try yet" (queues, quota) |
| `nodeName` | nothing – skips the scheduler | — | debugging only |

All the affinity rules end in **`IgnoredDuringExecution`**: they are only
evaluated when the pod is scheduled. Changing node labels later does not move
or evict running pods. (Only `NoExecute` taints act on running pods. If you
want rebalancing, look at the
[descheduler](https://github.com/kubernetes-sigs/descheduler) project.)

### topologyKey: what is a "domain"?

Pod affinity, anti-affinity and topology spread all group nodes into
**domains** by the value of a node label – the `topologyKey`:

```
topologyKey: kubernetes.io/hostname         topologyKey: training/zone
┌──────────┐ ┌──────────┐ ┌──────────┐      ┌──────── zone-a ───────┐ ┌──────── zone-b ───────┐
│ worker   │ │ worker2  │ │ control- │      │ worker  (+ any other  │ │ worker2 (+ any other  │
│          │ │          │ │ plane    │      │ zone-a nodes)         │ │ zone-b nodes)         │
└──────────┘ └──────────┘ └──────────┘      └───────────────────────┘ └───────────────────────┘
 every node is its own domain               control-plane has no training/zone label:
                                            it belongs to NO domain
```

"Anti-affinity on `hostname`" = never two on the same **node**.
"Anti-affinity on `training/zone`" = never two in the same **zone**, even on
different nodes. In this training cluster each zone happens to contain exactly
one node, so both behave the same here – in a real cloud cluster
(`topology.kubernetes.io/zone`, many nodes per zone) they are very different.
Real clusters use the well-known labels `topology.kubernetes.io/zone` and
`topology.kubernetes.io/region`; we use our own `training/zone` because kind
doesn't set them.

### The "first pod of a self-affine group" rule

Required pod affinity normally needs a matching pod to **already exist**. So a
group of pods that all say *"put me next to a pod of my group"* could never
start – there is no first member to be next to. The scheduler has an explicit
exception for this (InterPodAffinity filter):

> If **no** existing pod matches the pod's required affinity terms, **and** the
> pod's **own** labels match all of those terms, the affinity is treated as
> satisfied on every node that has the `topologyKey` label.

So the first pod lands wherever the other rules allow, and every later member
must follow it into the same domain. Two things to remember:

* It only works if the pod matches its **own** term (06-pending-pod.yaml shows
  a pod that doesn't, and stays Pending forever).
* Affinity counts pods that are **scheduled** (bound to a node), not pods that
  are Ready. It is a placement rule, never an ordering or readiness guarantee.

This is exactly what you need when two different pods must share a
**ReadWriteOnce** volume (RWO = mountable on *one node*, by any number of pods
on that node): give both a common label plus a required pod affinity on it.
The full, tested patterns (including ordering pod B after pod A) are in
[`scenarios/rwo-pvc-ordered-pods`](../../scenarios/rwo-pvc-ordered-pods/README.md).

### Taints and tolerations

A **taint** on a node repels pods; a **toleration** on a pod lets it ignore a
matching taint. A toleration **never attracts** a pod – combine it with node
affinity if the pod must run on that node.

```bash
kubectl taint nodes NODE key=value:Effect      # add
kubectl taint nodes NODE key=value:Effect-     # remove one (trailing dash)
kubectl taint nodes NODE key-                  # remove all effects of a key
```

| Effect | New pods without toleration | Already-running pods without toleration |
|---|---|---|
| `NoSchedule` | not scheduled there | stay |
| `PreferNoSchedule` | avoided if possible | stay |
| `NoExecute` | not scheduled there | **evicted** (immediately, or after `tolerationSeconds`) |

Kubernetes taints nodes itself: `node-role.kubernetes.io/control-plane:NoSchedule`
(kubeadm/kind), `node.kubernetes.io/not-ready`, `…/unreachable`,
`…/disk-pressure`, `…/memory-pressure`, `…/unschedulable` (set by
`kubectl cordon`). DaemonSets automatically get tolerations for most of these
([module 09](../09-daemonsets/README.md)).

### Topology spread

```
skew of a domain = (matching pods in it, after placing the new pod) − (matching pods in the emptiest domain)
```

`maxSkew: 1` + `whenUnsatisfiable: DoNotSchedule` = "keep the domains within
one pod of each other or don't schedule". `ScheduleAnyway` turns it into a
scoring hint. Two fields save you from the classic surprises:

* `matchLabelKeys: [pod-template-hash]` – count only pods of the **same
  ReplicaSet**. Without it, old pods being replaced during a rolling update are
  counted too, and the new ReplicaSet can end up unbalanced.
* `nodeTaintsPolicy: Honor` – ignore nodes whose taints the pod doesn't
  tolerate. The default (`Ignore`) counts a tainted node as an empty domain,
  which can make the constraint impossible to satisfy (lab step 9).

The scheduler also applies default, soft (`ScheduleAnyway`) spreading over
hostname and `topology.kubernetes.io/zone` to pods that have no constraints of
their own and belong to a Service, ReplicaSet or StatefulSet.

### Priority and preemption

`PriorityClass` (cluster-scoped) → `spec.priorityClassName` → integer
`spec.priority`. Higher-priority pods are scheduled first; if one doesn't fit,
the scheduler looks for a node where deleting **lower-priority** pods would make
room, deletes them (graceful termination, event `Preempted`) and sets the
pod's `status.nominatedNodeName`. It only picks victims whose removal actually
helps, prefers violating as few PodDisruptionBudgets as possible, and never
preempts pods of equal or higher priority. `preemptionPolicy: Never` gives a
class queue priority without the right to evict.

### Reading a FailedScheduling message

```
0/3 nodes are available: 1 node(s) had untolerated taint {node-role.kubernetes.io/control-plane: },
2 node(s) didn't match pod anti-affinity rules. preemption: 0/3 nodes are available:
1 Preemption is not helpful for scheduling, 2 No preemption victims found for incoming pod.
```

* `0/3 nodes are available` – how many nodes passed **all** filters.
* Then one entry per reason: **each node is counted under the filter that
  rejected it** (the numbers add up to the node count, except that a single
  filter can list several reasons, e.g. `Insufficient cpu, Insufficient memory`).
* `preemption: …` – the result of the preemption attempt.
  *"Preemption is not helpful"* = that node was rejected for something evicting
  pods can't fix (taint, affinity, nodeSelector). *"No preemption victims
  found"* = evicting could help in theory, but there are no lower-priority pods
  whose removal would make the pod fit.

| Phrase in the event | Look at |
|---|---|
| `didn't match Pod's node affinity/selector` | `nodeSelector`, node affinity vs `kubectl get nodes --show-labels` |
| `had untolerated taint {k: v}` | `kubectl describe node` → Taints, pod `tolerations` |
| `didn't match pod affinity rules` / `pod anti-affinity rules` | which pods exist (`kubectl get pods -o wide -l ...`), `topologyKey` |
| `didn't match pod topology spread constraints` | current distribution, `maxSkew`, `nodeTaintsPolicy` |
| `Insufficient cpu` / `memory` / `<extended resource>` | requests vs `kubectl describe node` → Allocated resources |
| `node(s) were unschedulable` | node is cordoned (`kubectl uncordon`) |
| `volume node affinity conflict` / `didn't find available persistent volumes` | the PV is pinned to another node ([module 06](../06-storage/README.md)) |

## Files

| File | What it demonstrates |
|---|---|
| [`00-namespace.yaml`](00-namespace.yaml) | The `lab-scheduling` namespace |
| [`01-nodeselector.yaml`](01-nodeselector.yaml) | `nodeSelector` on `training/zone=zone-a` |
| [`02-node-affinity.yaml`](02-node-affinity.yaml) | Required (`Exists`) + preferred node affinity with weights 80/20 |
| [`03-pod-anti-affinity.yaml`](03-pod-anti-affinity.yaml) | One `web` replica per node (required anti-affinity on hostname) |
| [`04-pod-affinity-cache.yaml`](04-pod-affinity-cache.yaml) | Redis cache co-located with each `web` pod (affinity + anti-affinity) |
| [`05-self-affinity.yaml`](05-self-affinity.yaml) | A self-affine group: all replicas follow the first one to its node |
| [`06-pending-pod.yaml`](06-pending-pod.yaml) | A pod that stays Pending (affinity to pods that don't exist) |
| [`07-taints-tolerations.yaml`](07-taints-tolerations.yaml) | Dedicated node: taint + toleration + node affinity |
| [`08-noexecute.yaml`](08-noexecute.yaml) | `NoExecute` eviction, `tolerationSeconds` |
| [`09-topology-spread.yaml`](09-topology-spread.yaml) | Spread over zones; the tainted-node gotcha and `nodeTaintsPolicy: Honor` |
| [`10-priorityclasses.yaml`](10-priorityclasses.yaml) | `lab-high` and `lab-low` PriorityClasses (cluster-scoped) |
| [`11-preemption-low.yaml`](11-preemption-low.yaml) | Low-priority pods that use up a (fake) extended resource |
| [`12-preemption-high.yaml`](12-preemption-high.yaml) | High-priority pod that preempts one of them |
| [`13-scheduling-gates.yaml`](13-scheduling-gates.yaml) | A pod held back by `schedulingGates` |
| [`14-nodename.yaml`](14-nodename.yaml) | Manual scheduling with `nodeName` (bypasses taints!) |
| [`exercises/`](exercises/) / [`solutions/`](solutions/) | Exercise files and reference answers |

## Lab

You need the 3-node training cluster (`make cluster-up`). Run all commands from
the repo root. Pod names, IPs and – where the scheduler has a free choice – nodes
will differ on your machine.

### 1. Look at the nodes

```bash
kubectl get nodes -L training/zone
kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints
```

```
NAME                          STATUS   ROLES           AGE   VERSION   ZONE
kube-training-control-plane   Ready    control-plane   10m   v1.33.1
kube-training-worker          Ready    <none>          10m   v1.33.1   zone-a
kube-training-worker2         Ready    <none>          10m   v1.33.1   zone-b

NAME                          TAINTS
kube-training-control-plane   [map[effect:NoSchedule key:node-role.kubernetes.io/control-plane]]
kube-training-worker          <none>
kube-training-worker2         <none>
```

Two schedulable workers in two "zones"; the control-plane is tainted, so normal
pods never land there. Keep this picture in mind – it explains most of the
events below.

### 2. nodeSelector

```bash
kubectl apply -f modules/10-scheduling/00-namespace.yaml -f modules/10-scheduling/01-nodeselector.yaml
kubectl -n lab-scheduling get pods -l app=zone-a-only -o wide
```

```
NAME                          READY   STATUS    RESTARTS   AGE   IP            NODE                   ...
zone-a-only-b479cdc69-gvvms   1/1     Running   0          3s    10.244.1.24   kube-training-worker   ...
zone-a-only-b479cdc69-m85n4   1/1     Running   0          3s    10.244.1.25   kube-training-worker   ...
zone-a-only-b479cdc69-mxth6   1/1     Running   0          3s    10.244.1.23   kube-training-worker   ...
```

Now ask for a zone that doesn't exist and read the scheduler's answer:

```bash
kubectl -n lab-scheduling patch deployment zone-a-only \
  -p '{"spec":{"template":{"spec":{"nodeSelector":{"training/zone":"zone-c"}}}}}'
kubectl -n lab-scheduling get pods -l app=zone-a-only
kubectl -n lab-scheduling get events --field-selector reason=FailedScheduling
```

```
NAME                           READY   STATUS    RESTARTS   AGE
zone-a-only-6c9b64c8b7-gcgjv   0/1     Pending   0          0s
zone-a-only-b479cdc69-djpbj    1/1     Running   0          11s
...
... FailedScheduling  pod/zone-a-only-6c9b64c8b7-gcgjv  0/3 nodes are available: 1 node(s) had untolerated
taint {node-role.kubernetes.io/control-plane: }, 2 node(s) didn't match Pod's node affinity/selector.
preemption: 0/3 nodes are available: 3 Preemption is not helpful for scheduling.
```

The control-plane is ruled out by its taint, both workers by the selector.
(The old pods keep running because the rolling update can't make progress –
[module 03](../03-deployments/README.md).) Undo it:

```bash
kubectl -n lab-scheduling rollout undo deployment zone-a-only
```

### 3. Node affinity: required + preferred

```bash
kubectl apply -f modules/10-scheduling/02-node-affinity.yaml
kubectl -n lab-scheduling get pods -l app=prefers-zone-b -o wide
```

```
NAME                              READY   STATUS    ...   NODE
prefers-zone-b-56cfbb56c9-4kfmw   1/1     Running   ...   kube-training-worker2
prefers-zone-b-56cfbb56c9-56wtg   1/1     Running   ...   kube-training-worker2
prefers-zone-b-56cfbb56c9-l7hw5   1/1     Running   ...   kube-training-worker2
prefers-zone-b-56cfbb56c9-qbpvs   1/1     Running   ...   kube-training-worker2
```

The required term (`training/zone Exists`) leaves the two workers; the
preferred terms give zone-b 80 points and zone-a 20, so all four land on
worker2. "Preferred" is still only a score: if worker2 were full or tainted,
they'd go to worker – you'll see exactly that happen in step 8.

### 4. Pod anti-affinity: one per node, and your first FailedScheduling

```bash
kubectl apply -f modules/10-scheduling/03-pod-anti-affinity.yaml
kubectl -n lab-scheduling get pods -l app=web -o wide
kubectl -n lab-scheduling scale deployment web --replicas=3
kubectl -n lab-scheduling get pods -l app=web -o wide
kubectl -n lab-scheduling get events --field-selector reason=FailedScheduling
```

```
web-7757f8cd9f-7r4cx   1/1     Running   0          2s    10.244.2.19   kube-training-worker2
web-7757f8cd9f-97tsn   1/1     Running   0          2s    10.244.1.26   kube-training-worker
web-7757f8cd9f-v5lkc   0/1     Pending   0          0s    <none>        <none>

... FailedScheduling   pod/web-7757f8cd9f-v5lkc   0/3 nodes are available: 1 node(s) had untolerated
taint {node-role.kubernetes.io/control-plane: }, 2 node(s) didn't match pod anti-affinity rules.
preemption: 0/3 nodes are available: 1 Preemption is not helpful for scheduling, 2 No preemption
victims found for incoming pod.
```

Decode it with the table in *Concepts*: 3 nodes, 1 rejected by the taint,
2 by anti-affinity (each already runs a `web` pod), and preemption can't help
(the other web pods have the same priority). A required anti-affinity on
hostname caps the replica count at the number of nodes. Scale back:

```bash
kubectl -n lab-scheduling scale deployment web --replicas=2
```

### 5. Pod affinity: a cache next to every web pod

```bash
kubectl apply -f modules/10-scheduling/04-pod-affinity-cache.yaml
kubectl -n lab-scheduling get pods -l 'app in (web,cache)' -o wide
```

```
NAME                    READY   STATUS    ...   NODE
cache-85cb4956b-577nl   1/1     Running   ...   kube-training-worker2
cache-85cb4956b-7q7ww   1/1     Running   ...   kube-training-worker
web-7757f8cd9f-7r4cx    1/1     Running   ...   kube-training-worker2
web-7757f8cd9f-97tsn    1/1     Running   ...   kube-training-worker
```

Affinity says "only where a `web` pod is", anti-affinity says "not where a
`cache` pod already is" → exactly one cache per web pod.

### 6. The self-affine group, and a pod that waits forever

```bash
kubectl apply -f modules/10-scheduling/05-self-affinity.yaml
kubectl -n lab-scheduling get pods -l app=self-affine -o wide
```

```
self-affine-6fc56f879d-9flmn   1/1     Running   0          3s    10.244.2.22   kube-training-worker2
self-affine-6fc56f879d-hxsxt   1/1     Running   0          3s    10.244.2.23   kube-training-worker2
self-affine-6fc56f879d-nvh74   1/1     Running   0          3s    10.244.2.21   kube-training-worker2
```

No `app=self-affine` pod existed, yet the first replica scheduled: its own
labels match its affinity term, so the *first pod of a self-affine group* rule
applied. Replicas 2 and 3 then had to follow it. (Your group may pick the other
worker – that's the point: the scheduler chooses, the group sticks together.)

Now a pod whose affinity points at pods that don't exist **and** that doesn't
match its own term:

```bash
kubectl apply -f modules/10-scheduling/06-pending-pod.yaml
kubectl -n lab-scheduling describe pod waits-for-db | sed -n '/^Events/,$p'
```

```
Events:
  Type     Reason            Age   From               Message
  ----     ------            ----  ----               -------
  Warning  FailedScheduling  0s    default-scheduler  0/3 nodes are available: 1 node(s) had untolerated
  taint {node-role.kubernetes.io/control-plane: }, 2 node(s) didn't match pod affinity rules. preemption:
  0/3 nodes are available: 3 Preemption is not helpful for scheduling.
```

Give it what it wants – a pod labelled `app=database` (quick imperative way):

```bash
kubectl -n lab-scheduling run database --image=redis:7.4-alpine --labels=app=database
kubectl -n lab-scheduling get pods -l 'app in (database,waits-for-db)' -o wide
```

```
NAME           READY   STATUS    RESTARTS   AGE   IP            NODE
database       1/1     Running   0          3s    10.244.2.24   kube-training-worker2
waits-for-db   1/1     Running   0          3s    10.244.2.25   kube-training-worker2
```

Within a second the scheduler retried `waits-for-db` (a new pod is a "relevant
event") and put it next to the database. Look at the events of `waits-for-db`:
it was scheduled as soon as `database` was **bound to a node** – not when the
database was ready. Affinity is about placement, not about start order.

### 7. Taints: a dedicated node (NoSchedule, then PreferNoSchedule)

> **This step changes a node.** Remove the taint at the end of the step (the
> commands are below and in *Cleanup*).

```bash
kubectl taint nodes kube-training-worker2 lab-scheduling/dedicated=special:NoSchedule
kubectl apply -f modules/10-scheduling/07-taints-tolerations.yaml
kubectl -n lab-scheduling get pods -l 'app in (regular,dedicated)' -o wide
```

```
NAME                        READY   STATUS    ...   NODE
dedicated-f76577948-4szn5   1/1     Running   ...   kube-training-worker2
dedicated-f76577948-wnx7k   1/1     Running   ...   kube-training-worker2
regular-69d5999b46-67xf6    1/1     Running   ...   kube-training-worker
regular-69d5999b46-c8p89    1/1     Running   ...   kube-training-worker
regular-69d5999b46-h75hr    1/1     Running   ...   kube-training-worker
regular-69d5999b46-l6bq6    1/1     Running   ...   kube-training-worker
```

`regular` can't use worker2; `dedicated` tolerates the taint and its node
affinity pulls it there. Note that the pods from earlier steps that were
already running on worker2 are untouched – `NoSchedule` only affects new
placements.

Switch the taint to the soft effect and add more `regular` pods:

```bash
kubectl taint nodes kube-training-worker2 lab-scheduling/dedicated-
kubectl taint nodes kube-training-worker2 lab-scheduling/dedicated=special:PreferNoSchedule
kubectl -n lab-scheduling scale deployment regular --replicas=8
kubectl -n lab-scheduling get pods -l app=regular -o wide
```

All 8 still land on `kube-training-worker`: the scheduler avoids the
`PreferNoSchedule` node as long as another node fits. It would use worker2 only
if worker couldn't take them. Clean up the taint and scale back:

```bash
kubectl taint nodes kube-training-worker2 lab-scheduling/dedicated-
kubectl -n lab-scheduling scale deployment regular --replicas=4
```

### 8. NoExecute: evicting running pods

> **This step changes a node** and evicts every pod in `lab-scheduling` (and
> anywhere else!) that runs on worker2 and doesn't tolerate the taint. On your
> own laptop cluster that's fine; never do this on a shared cluster.

```bash
kubectl apply -f modules/10-scheduling/08-noexecute.yaml
kubectl -n lab-scheduling wait --for=condition=Ready pod -l app=noexecute-demo
```

First, notice the tolerations Kubernetes added to **every** pod by itself:

```bash
kubectl -n lab-scheduling get pod evict-now \
  -o jsonpath='{range .spec.tolerations[*]}{.key}{"  "}{.effect}{"  "}{.tolerationSeconds}{"\n"}{end}'
```

```
node.kubernetes.io/not-ready  NoExecute  300
node.kubernetes.io/unreachable  NoExecute  300
```

That's why pods on a dead node are replaced only after ~5 minutes. Now watch
the demo pods in a second terminal and taint the node:

```bash
kubectl -n lab-scheduling get pods -l app=noexecute-demo -w      # terminal 2
kubectl taint nodes kube-training-worker2 lab-scheduling/maintenance=now:NoExecute
```

```
NAME              READY   STATUS        RESTARTS   AGE
evict-after-30s   1/1     Running       0          3s
evict-now         1/1     Running       0          3s
never-evicted     1/1     Running       0          3s
evict-now         1/1     Terminating   0          4s      <- right away
evict-now         0/1     Error         0          6s
evict-after-30s   1/1     Terminating   0          33s     <- 30 s after the taint
evict-after-30s   0/1     Error         0          33s
```

(`Error` just means whoami exited with a non-zero code on SIGTERM.)
`never-evicted` keeps running. Now look at the whole namespace:

```bash
kubectl -n lab-scheduling get pods -o wide
kubectl -n lab-scheduling get events --field-selector reason=TaintManagerEviction
```

```
NAME                              READY   STATUS    ...   NODE
cache-85cb4956b-7d9p9             0/1     Pending   ...   <none>
dedicated-f76577948-hgpjn         0/1     Pending   ...   <none>
dedicated-f76577948-nm6wx         0/1     Pending   ...   <none>
never-evicted                     1/1     Running   ...   kube-training-worker2
prefers-zone-b-56cfbb56c9-4fmxl   1/1     Running   ...   kube-training-worker
prefers-zone-b-56cfbb56c9-dzrm4   1/1     Running   ...   kube-training-worker
...
self-affine-6fc56f879d-mpcdn      0/1     Pending   ...   <none>
web-7757f8cd9f-cwqjx              0/1     Pending   ...   <none>
...
LAST SEEN   TYPE     REASON                 OBJECT                           MESSAGE
31s         Normal   TaintManagerEviction   pod/cache-85cb4956b-577nl        Marking for deletion Pod lab-scheduling/cache-85cb4956b-577nl
31s         Normal   TaintManagerEviction   pod/dedicated-f76577948-4szn5    Marking for deletion Pod lab-scheduling/dedicated-f76577948-4szn5
...
```

Everything from the earlier steps that ran on worker2 was evicted too, and
each Deployment immediately created a replacement:

* `prefers-zone-b` only *prefers* zone-b → replacements went to worker.
* `web` (one per node) and `cache` (next to a web, one per node) can't fit on
  worker alone → Pending.
* `dedicated` requires zone-b → Pending.
* `self-affine`: the replacements were created while the old replicas were
  still terminating on worker2, so their affinity pointed at worker2 → Pending.
  A pod marked unschedulable is only retried when a relevant cluster event
  happens (or after at most 5 minutes) – here that event is the taint removal.

Remove the taint and everything comes back:

```bash
kubectl taint nodes kube-training-worker2 lab-scheduling/maintenance-
kubectl -n lab-scheduling delete pod never-evicted
kubectl -n lab-scheduling get pods -o wide        # all Running again
```

The eviction is done by the taint-eviction controller in
kube-controller-manager, which is why the event source is not the kubelet.
`kubectl drain` uses a gentler mechanism (the Eviction API, which respects
PodDisruptionBudgets) – see the Further reading links.

### 9. Topology spread (and a classic gotcha)

```bash
kubectl apply -f modules/10-scheduling/09-topology-spread.yaml
kubectl -n lab-scheduling get pods -l 'app in (spread-zones,spread-nodes-strict)' -o wide
```

```
NAME                                   READY   STATUS    ...   NODE
spread-nodes-strict-7f98479668-fwjss   1/1     Running   ...   kube-training-worker
spread-nodes-strict-7f98479668-px48c   0/1     Pending   ...   <none>
spread-nodes-strict-7f98479668-rwg5z   1/1     Running   ...   kube-training-worker2
spread-nodes-strict-7f98479668-tsvks   0/1     Pending   ...   <none>
spread-zones-7988d77bc9-hvcck          1/1     Running   ...   kube-training-worker
spread-zones-7988d77bc9-m8mt6          1/1     Running   ...   kube-training-worker2
spread-zones-7988d77bc9-s88jp          1/1     Running   ...   kube-training-worker2
spread-zones-7988d77bc9-stvc8          1/1     Running   ...   kube-training-worker
```

`spread-zones` is a perfect 2 + 2. But why are two `spread-nodes-strict` pods
Pending when both workers obviously have room?

```bash
kubectl -n lab-scheduling describe pod -l app=spread-nodes-strict | grep FailedScheduling
```

```
Warning  FailedScheduling  3s  default-scheduler  0/3 nodes are available: 1 node(s) had untolerated
taint {node-role.kubernetes.io/control-plane: }, 2 node(s) didn't match pod topology spread constraints. ...
```

The control-plane also has a `kubernetes.io/hostname` label, so it is a domain
– with **0** pods, because nobody can schedule there. With the default
`nodeTaintsPolicy: Ignore` it still counts, so placing a 2nd pod on a worker
would mean skew 2 − 0 = 2 > `maxSkew` 1. Tell the scheduler to ignore domains
the pod can't use anyway:

```bash
kubectl -n lab-scheduling patch deployment spread-nodes-strict --type=json \
  -p '[{"op":"add","path":"/spec/template/spec/topologySpreadConstraints/0/nodeTaintsPolicy","value":"Honor"}]'
kubectl -n lab-scheduling get pods -l app=spread-nodes-strict -o wide
```

```
spread-nodes-strict-668454b497-8dls7   1/1     Running   ...   kube-training-worker2
spread-nodes-strict-668454b497-hzrcl   1/1     Running   ...   kube-training-worker
spread-nodes-strict-668454b497-k7jrj   1/1     Running   ...   kube-training-worker2
spread-nodes-strict-668454b497-t5vs9   1/1     Running   ...   kube-training-worker
```

2 + 2 – and thanks to `matchLabelKeys: [pod-template-hash]` the rollout
counted only the new ReplicaSet's pods. (Without it, the old pods that were
still running during the rollout are counted and you can end up with 3 + 1.)

### 10. PriorityClasses and preemption

To make preemption deterministic on any laptop, we invent a resource that only
our pods use: **2 "widgets" on kube-training-worker**. Extended resources are
advertised by patching the node's status (this is what device plugins do for
GPUs).

> **This step changes a node.** The *Cleanup* section removes the widgets.

```bash
kubectl apply -f modules/10-scheduling/10-priorityclasses.yaml
kubectl get priorityclasses

kubectl patch node kube-training-worker --subresource=status --type=json \
  -p '[{"op":"add","path":"/status/capacity/training.example.com~1widget","value":"2"}]'
# "~1" is how JSON Patch writes "/" inside a key. Wait until the kubelet reports it:
kubectl get node kube-training-worker -o jsonpath='{.status.allocatable.training\.example\.com/widget}{"\n"}'
```

```
NAME                      VALUE        GLOBAL-DEFAULT   AGE   PREEMPTIONPOLICY
lab-high                  100000       false            0s    PreemptLowerPriority
lab-low                   1000         false            0s    PreemptLowerPriority
system-cluster-critical   2000000000   false            11m   PreemptLowerPriority
system-node-critical      2000001000   false            11m   PreemptLowerPriority
node/kube-training-worker patched
2
```

Fill the node with two low-priority widget users, then add a high-priority one:

```bash
kubectl apply -f modules/10-scheduling/11-preemption-low.yaml
kubectl -n lab-scheduling get pods -l app=low-prio -o wide
kubectl apply -f modules/10-scheduling/12-preemption-high.yaml
kubectl -n lab-scheduling get pods -l 'app in (low-prio,high-prio)' -o wide
kubectl -n lab-scheduling get events --field-selector reason=Preempted
```

```
NAME                        READY   STATUS    ...   NODE
high-prio                   1/1     Running   ...   kube-training-worker
low-prio-59f9965878-4g6t8   0/1     Pending   ...   <none>
low-prio-59f9965878-s7dgd   1/1     Running   ...   kube-training-worker

LAST SEEN   TYPE     REASON      OBJECT                          MESSAGE
5s          Normal   Preempted   pod/low-prio-59f9965878-zd6jn   Preempted by pod 6e8def06-... on node kube-training-worker
```

One `low-prio` pod was preempted; its Deployment created a replacement that now
waits:

```bash
kubectl -n lab-scheduling describe pod -l app=low-prio | grep FailedScheduling | tail -1
```

```
Warning  FailedScheduling  3s (x3 over 5s)  default-scheduler  0/3 nodes are available: 1 node(s) had
untolerated taint {node-role.kubernetes.io/control-plane: }, 2 Insufficient training.example.com/widget.
preemption: 0/3 nodes are available: 1 Preemption is not helpful for scheduling, 2 Insufficient
training.example.com/widget.
```

Now look at who else lives on that node:

```bash
kubectl get pods -A --field-selector spec.nodeName=kube-training-worker \
  -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,PRIORITY:.spec.priority
```

Lots of pods with priority **0** – lower than `lab-low` – and none of them was
touched: preemption only removes pods whose removal actually makes the new pod
fit. That's also why this demo is safe on a busy cluster, while a CPU-based one
could evict anything. On a real cluster, be careful with high priorities: a
`globalDefault` or a too-generous class can evict other teams' workloads.

### 11. Scheduling gates

```bash
kubectl apply -f modules/10-scheduling/13-scheduling-gates.yaml
kubectl -n lab-scheduling get pod gated
kubectl -n lab-scheduling get pod gated -o jsonpath='{.status.conditions[?(@.type=="PodScheduled")].message}{"\n"}'
```

```
NAME    READY   STATUS            RESTARTS   AGE
gated   0/1     SchedulingGated   0          0s
Scheduling is blocked due to non-empty scheduling gates
```

No FailedScheduling events – the scheduler isn't even trying. Gates can only be
removed, never added:

```bash
kubectl -n lab-scheduling patch pod gated --type=json \
  -p '[{"op":"add","path":"/spec/schedulingGates/-","value":{"name":"training.example.com/another"}}]'
```

```
The Pod "gated" is invalid: spec.schedulingGates[1].name: Forbidden: only deletion is allowed, but found new scheduling gate 'training.example.com/another'
```

Release it:

```bash
kubectl -n lab-scheduling patch pod gated --type=json -p '[{"op":"remove","path":"/spec/schedulingGates"}]'
kubectl -n lab-scheduling get pod gated -o wide          # Running
```

While a pod is gated you may still *narrow* its placement, e.g. add a
`nodeSelector` – that's how queueing systems such as Kueue decide where a batch
job runs before letting it go.

### 12. nodeName: skipping the scheduler

```bash
kubectl apply -f modules/10-scheduling/14-nodename.yaml
kubectl -n lab-scheduling get pod manual -o wide
kubectl -n lab-scheduling describe pod manual | sed -n '/^Events/,$p'
```

```
NAME     READY   STATUS    RESTARTS   AGE   IP           NODE
manual   1/1     Running   0          3s    10.244.0.5   kube-training-control-plane

Events:
  Type    Reason   Age   From     Message
  ----    ------   ----  ----     -------
  Normal  Pulled   2s    kubelet  Container image "traefik/whoami:v1.10" already present on machine
  Normal  Created  2s    kubelet  Created container: app
  Normal  Started  1s    kubelet  Started container app
```

It runs on the **tainted control-plane** without a toleration, and there is no
`Scheduled` event from `default-scheduler`: the scheduler never saw it. All the
safety nets of this module were skipped. Use labels + `nodeSelector`/affinity
instead.

## Exercises

1. **Pending detective.** Apply
   [`exercises/01-broken-pending.yaml`](exercises/01-broken-pending.yaml).
   Without reading the YAML first, use only `kubectl get events` /
   `kubectl describe` to explain why the pods are Pending, then fix the file so
   the pods run in zone-b.
   *Hint:* `nodeSelector` and node affinity are ANDed.
   Solution: [`solutions/01-fixed.yaml`](solutions/01-fixed.yaml).

2. **The ghost node.** Create a pod bound to a node that doesn't exist:
   `kubectl -n lab-scheduling run ghost --image=traefik/whoami:v1.10 --overrides='{"spec":{"nodeName":"no-such-node"}}'`.
   What do `get pod -o wide` and `describe` show? Are there any scheduler
   events? Watch it for two minutes.
   *Hint:* the pod garbage collector in kube-controller-manager deletes pods
   bound to nodes that don't exist (after a short quarantine – about a minute
   in our test).

3. **Tolerations don't attract.** With
   `kubectl taint nodes kube-training-worker2 lab-scheduling/dedicated=special:NoSchedule`
   in place, create a Deployment with 6 replicas that has *only* the toleration
   from `07-taints-tolerations.yaml` (no affinity). Where do the pods go? Then
   make worker2 really "dedicated". Don't forget to untaint afterwards.
   *Hint:* `kubectl create deployment ... --dry-run=client -o yaml` and add the
   toleration; expect roughly 3 + 3. The fix is the node affinity in
   `dedicated`.

4. **Spread vs anti-affinity.** Write a Deployment with 5 replicas that spreads
   evenly over `training/zone` but – unlike `web` in step 4 – can run more
   than one replica per zone. What distribution do you get? What happens to
   `web` if you scale it to 5?
   Solution: [`solutions/04-zone-spread.yaml`](solutions/04-zone-spread.yaml)
   (3 + 2; `web` would have 3 Pending replicas).

5. **Two workloads, one node (RWO preparation).** Create two *different*
   Deployments, `writer` (1 replica) and `reader` (2 replicas), that must
   always run on the same node – without naming a node or a zone. Delete all
   their pods at once and check they still end up together.
   *Hint:* a shared label plus the self-affine rule from step 6. Read
   [`scenarios/rwo-pvc-ordered-pods`](../../scenarios/rwo-pvc-ordered-pods/README.md)
   afterwards to see this used with a real ReadWriteOnce volume.
   Solution: [`solutions/05-co-located-pair.yaml`](solutions/05-co-located-pair.yaml).

6. **Polite priority.** Redo step 10, but with a new PriorityClass
   `lab-high-polite` (same value, `preemptionPolicy: Never`). What does the
   FailedScheduling message say now? Then delete one `low-prio` pod by hand:
   who gets the freed widget – the polite pod or the Deployment's replacement
   `low-prio` pod? Why?
   *Hint:* the scheduling queue is sorted by priority.
   Solution: [`solutions/06-polite-priority.yaml`](solutions/06-polite-priority.yaml)
   (message: `preemption: not eligible due to preemptionPolicy=Never`; the
   polite pod wins the widget).

## Cleanup

```bash
kubectl delete namespace lab-scheduling
kubectl delete priorityclass lab-high lab-low
kubectl delete priorityclass lab-high-polite --ignore-not-found        # exercise 6

# Node changes - each command is harmless if the change is already gone
# (taint: "not found" error you can ignore).
kubectl taint nodes kube-training-worker2 lab-scheduling/dedicated-
kubectl taint nodes kube-training-worker2 lab-scheduling/maintenance-
kubectl patch node kube-training-worker --subresource=status --type=json \
  -p '[{"op":"remove","path":"/status/capacity/training.example.com~1widget"}]'

# Check: no lab taints, no widgets
kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints
kubectl get node kube-training-worker -o jsonpath='{.status.capacity}{"\n"}'
```

(The widget `remove` fails with "unable to find" if you never added it – fine.)

## Further reading

* [Kubernetes Scheduler](https://kubernetes.io/docs/concepts/scheduling-eviction/kube-scheduler/)
* [Assigning Pods to Nodes](https://kubernetes.io/docs/concepts/scheduling-eviction/assign-pod-node/) – nodeSelector, affinity, nodeName
* [Taints and Tolerations](https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/)
* [Pod Topology Spread Constraints](https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/)
* [Pod Priority and Preemption](https://kubernetes.io/docs/concepts/scheduling-eviction/pod-priority-preemption/)
* [Pod Scheduling Readiness (scheduling gates)](https://kubernetes.io/docs/concepts/scheduling-eviction/pod-scheduling-readiness/)
* [Advertise Extended Resources for a Node](https://kubernetes.io/docs/tasks/administer-cluster/extended-resource-node/)
* [Well-Known Labels, Annotations and Taints](https://kubernetes.io/docs/reference/labels-annotations-taints/)
* [Scheduling Framework](https://kubernetes.io/docs/concepts/scheduling-eviction/scheduling-framework/) – plugins, filter/score
* [Safely Drain a Node](https://kubernetes.io/docs/tasks/administer-cluster/safely-drain-node/) and [API-initiated Eviction](https://kubernetes.io/docs/concepts/scheduling-eviction/api-eviction/)
