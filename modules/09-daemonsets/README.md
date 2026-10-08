# Module 09 – DaemonSets

## Goal

Run exactly one copy of a pod on every node, or on a chosen subset of nodes,
the way cluster agents such as kube-proxy, CNI plugins, log shippers and
node-exporter do. Control where those pods go and how they are updated.

## What you'll learn

* How a DaemonSet decides where its pods run: one pod per eligible node,
  automatically following nodes as they come and go.
* Why DaemonSet pods skip the control-plane node by default (a taint), and
  how a toleration changes that.
* Targeting a subset of nodes with `nodeSelector` (`training/zone`).
* Update strategies: `RollingUpdate` with `maxUnavailable` / `maxSurge`, and
  `OnDelete`.
* What real DaemonSets look like (`kubectl get ds -n kube-system`) and the
  traits they share.

## Concepts

### One pod per node

A DaemonSet has no `replicas` field. Its controller computes the set of
**eligible nodes** and makes sure each has exactly one pod:

```
eligible nodes = all nodes
               ∩ nodes matching nodeSelector / required node affinity
               − nodes with a taint the pod does not tolerate (NoSchedule / NoExecute)
```

* A node joins (or gains a matching label) → a pod is created there.
* A node is removed (or loses the label) → its pod is deleted.
* `kubectl get ds` shows `DESIRED` = number of eligible nodes.

Under the hood every DaemonSet pod is placed by the normal scheduler. The
controller pins each pod to its node with a required node affinity on
`metadata.name`, and automatically adds tolerations so agents keep running
when a node is in trouble:

| Toleration added automatically | Why |
|---|---|
| `node.kubernetes.io/not-ready:NoExecute`, `node.kubernetes.io/unreachable:NoExecute` (no time limit) | don't evict the agent when the node is unhealthy; it may be what fixes it |
| `node.kubernetes.io/disk-pressure`, `memory-pressure`, `pid-pressure`, `unschedulable` (`NoSchedule`) | still start on a node under pressure or cordoned for maintenance |
| `node.kubernetes.io/network-unavailable` (only with `hostNetwork: true`) | CNI agents must start before the network works |

The control-plane taint (`node-role.kubernetes.io/control-plane:NoSchedule`)
is **not** in that list. Your DaemonSet stays off control-plane nodes unless
it tolerates that taint explicitly. Taints and tolerations are covered in
depth in [module 10](../10-scheduling/README.md).

### Updating a DaemonSet

| Strategy | Behaviour |
|---|---|
| `RollingUpdate` (default) | Replace pods node by node. `maxUnavailable` (default 1) is how many nodes may be without a ready agent at once. `maxSurge` (default 0) is how many nodes may briefly run old + new pod side by side. |
| `RollingUpdate` with `maxSurge: 1, maxUnavailable: 0` | the new pod starts **before** the old one stops, so there's no gap in coverage. It can't work if the pod uses a `hostPort` (exercise 6) or another exclusive node resource. |
| `OnDelete` | never replace pods automatically. A node gets the new version when you delete its pod. Use it when restarts must be coordinated, e.g. one node at a time together with a drain. |

`minReadySeconds` makes the rollout wait until a new pod has been Ready for
that long before moving on. `kubectl rollout status|history|undo ds/<name>`
work like they do for Deployments. Revisions are stored as
ControllerRevisions, and each pod carries a `controller-revision-hash`
label.

### Real-world DaemonSets

| Agent | What it needs from the node |
|---|---|
| **kube-proxy** | programs iptables/nftables/IPVS for Services: `hostNetwork`, privileged |
| **CNI plugins** (kindnet here; Calico, Cilium, Flannel elsewhere) | sets up pod networking: `hostNetwork`, host paths `/etc/cni`, `/opt/cni` |
| **Log shippers** (Fluent Bit, Vector, Grafana Alloy) | read `/var/log/pods` and `/var/log/containers` via `hostPath` |
| **node-exporter** | node CPU, memory, disk and network metrics from `/proc` and `/sys`, often on a `hostPort` |
| **CSI node plugins**, **GPU device plugins** | mount volumes, advertise devices: privileged, kubelet sockets |
| Security agents (Falco and others) | kernel events: privileged, host PID |

What they have in common: they tolerate (almost) every taint,
`tolerations: [{operator: Exists}]`, so they run on every node. They use
`priorityClassName: system-node-critical`, so they are the last pods evicted
under resource pressure. And they have small, explicit resource requests,
because a DaemonSet's requests are multiplied by the number of nodes.

## Files

| File | What it demonstrates |
|---|---|
| [`00-namespace.yaml`](00-namespace.yaml) | the `lab-daemonsets` namespace |
| [`01-daemonset-node-agent.yaml`](01-daemonset-node-agent.yaml) | a node agent reading the node's `/var/log` read-only; `RollingUpdate` settings |
| [`02-daemonset-all-nodes.yaml`](02-daemonset-all-nodes.yaml) | toleration for the control-plane taint → pods on all 3 nodes |
| [`03-daemonset-zone-a.yaml`](03-daemonset-zone-a.yaml) | `nodeSelector: training/zone=zone-a` → 1 pod |
| [`solutions/`](solutions/) | reference answers for the exercises |

## Lab

```bash
cd modules/09-daemonsets
kubectl apply -f 00-namespace.yaml
```

### 1. One pod per worker

```bash
kubectl apply -f 01-daemonset-node-agent.yaml
kubectl rollout status ds/node-agent -n lab-daemonsets
kubectl get ds node-agent -n lab-daemonsets
kubectl get pods -n lab-daemonsets -l app=node-agent -o wide
kubectl logs -n lab-daemonsets -l app=node-agent --prefix
```

```
NAME         DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR   AGE
node-agent   2         2         2       2            2           <none>          6s
NAME               READY   STATUS    RESTARTS   AGE   IP             NODE
node-agent-2ljq2   1/1     Running   0          7s    10.244.1.235   kube-training-worker2
node-agent-t4xql   1/1     Running   0          7s    10.244.3.237   kube-training-worker
[pod/node-agent-2ljq2/agent] 11:04:36 agent v1.0 on kube-training-worker2 sees 12 pod log dirs
[pod/node-agent-t4xql/agent] 11:04:37 agent v1.0 on kube-training-worker sees 39 pod log dirs
```

Each agent reads its **own** node's `/var/log/pods`, so the counts differ.
Delete one of the pods and watch a replacement appear on the same node within
a second or two.

### 2. Why not on the control plane?

```bash
kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints
```

```
NAME                          TAINTS
kube-training-control-plane   [map[effect:NoSchedule key:node-role.kubernetes.io/control-plane]]
kube-training-worker          <none>
kube-training-worker2         <none>
```

Now look at what the DaemonSet controller put into one of its pods:

```bash
P=$(kubectl get pods -n lab-daemonsets -l app=node-agent -o jsonpath='{.items[0].metadata.name}')
kubectl get pod $P -n lab-daemonsets -o jsonpath='{range .spec.tolerations[*]}{.key}:{.effect}{"\n"}{end}'
kubectl get pod $P -n lab-daemonsets -o yaml | grep -A8 '^  affinity'
```

```
node.kubernetes.io/not-ready:NoExecute
node.kubernetes.io/unreachable:NoExecute
node.kubernetes.io/disk-pressure:NoSchedule
node.kubernetes.io/memory-pressure:NoSchedule
node.kubernetes.io/pid-pressure:NoSchedule
node.kubernetes.io/unschedulable:NoSchedule
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
        - matchFields:
          - key: metadata.name
            operator: In
            values:
            - kube-training-worker2
```

None of the six automatic tolerations matches `control-plane`, and every pod is
pinned to exactly one node by name.

### 3. Add a toleration: all three nodes

```bash
kubectl apply -f 02-daemonset-all-nodes.yaml
kubectl rollout status ds/node-agent-all -n lab-daemonsets
kubectl get ds node-agent-all -n lab-daemonsets
kubectl get pods -n lab-daemonsets -l app=node-agent-all -o custom-columns=POD:.metadata.name,NODE:.spec.nodeName
```

```
NAME             DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR   AGE
node-agent-all   3         3         3       3            3           <none>          2s
POD                    NODE
node-agent-all-jc4b6   kube-training-control-plane
node-agent-all-cmfqg   kube-training-worker
node-agent-all-qrf62   kube-training-worker2
```

### 4. Target a subset with nodeSelector

```bash
kubectl apply -f 03-daemonset-zone-a.yaml
kubectl get ds -n lab-daemonsets
kubectl get pods -n lab-daemonsets -l app=zone-a-agent -o wide
```

```
NAME             DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR          AGE
node-agent       2         2         2       2            2           <none>                 17s
node-agent-all   3         3         3       3            3           <none>                 2s
zone-a-agent     1         1         1       1            1           training/zone=zone-a   2s
```

Only `kube-training-worker` carries `training/zone=zone-a`
(`kubectl get nodes -L training/zone`), so `DESIRED` is 1.

### 5. The DaemonSets your cluster already runs

```bash
kubectl get ds -n kube-system
kubectl get ds kube-proxy -n kube-system -o jsonpath='{.spec.template.spec.tolerations}{"\n"}{.spec.template.spec.priorityClassName}{"\n"}'
kubectl get ds kindnet -n kube-system -o jsonpath='{.spec.template.spec.hostNetwork}{"\n"}{.spec.updateStrategy}{"\n"}'
```

```
NAME         DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR            AGE
kindnet      3         3         3       3            3           kubernetes.io/os=linux   29m
kube-proxy   3         3         3       3            3           kubernetes.io/os=linux   29m
[{"operator":"Exists"}]
system-node-critical
true
{"rollingUpdate":{"maxSurge":0,"maxUnavailable":1},"type":"RollingUpdate"}
```

`kube-proxy` and `kindnet` (the CNI plugin) tolerate **everything**, run as
`system-node-critical`, and use the host's network namespace. Their
`nodeSelector: kubernetes.io/os=linux` keeps them off Windows nodes in mixed
clusters.

### 6. Rolling update, default style: stop old, then start new

Watch in a second terminal:

```bash
kubectl get pods -n lab-daemonsets -l app=node-agent -o wide -w
```

Change the template:

```bash
kubectl set env ds/node-agent -n lab-daemonsets AGENT_VERSION=1.1
kubectl rollout status ds/node-agent -n lab-daemonsets
```

```
node-agent-2ljq2   1/1     Terminating         30s   kube-training-worker2
node-agent-2ljq2   0/1     Completed           31s   kube-training-worker2
node-agent-t982l   0/1     Pending             0s    kube-training-worker2
node-agent-t982l   0/1     ContainerCreating   0s    kube-training-worker2
node-agent-t982l   1/1     Running             1s    kube-training-worker2
node-agent-t4xql   1/1     Terminating         37s   kube-training-worker
node-agent-t4xql   0/1     Completed           38s   kube-training-worker
node-agent-wg6mg   0/1     Pending             0s    kube-training-worker
node-agent-wg6mg   1/1     Running             1s    kube-training-worker
```

`maxUnavailable: 1, maxSurge: 0`: one node at a time, and on each node the
old pod is gone *before* the new one starts. The next node starts about 6
seconds later (`minReadySeconds: 5`).

### 7. Rolling update with surge: start new, then stop old

```bash
kubectl patch ds node-agent -n lab-daemonsets \
  -p '{"spec":{"updateStrategy":{"rollingUpdate":{"maxSurge":1,"maxUnavailable":0}}}}'
kubectl set env ds/node-agent -n lab-daemonsets AGENT_VERSION=1.2
kubectl rollout status ds/node-agent -n lab-daemonsets
```

```
node-agent-st427   0/1     Pending             0s    kube-training-worker2
node-agent-st427   0/1     ContainerCreating   0s    kube-training-worker2
node-agent-st427   1/1     Running             1s    kube-training-worker2
node-agent-t982l   1/1     Terminating         21s   kube-training-worker2
node-agent-gtd8d   0/1     Pending             0s    kube-training-worker
node-agent-gtd8d   1/1     Running             2s    kube-training-worker
node-agent-wg6mg   1/1     Terminating         22s   kube-training-worker
```

Now the new pod runs first, and the old one is removed once the new one has
been ready for `minReadySeconds`. Each node always has an agent.

```bash
kubectl rollout history ds/node-agent -n lab-daemonsets
kubectl logs -n lab-daemonsets -l app=node-agent --prefix
```

```
REVISION  CHANGE-CAUSE
1         <none>
2         <none>
3         <none>
[pod/node-agent-gtd8d/agent] 11:05:29 agent v1.2 on kube-training-worker sees 25 pod log dirs
[pod/node-agent-st427/agent] 11:05:21 agent v1.2 on kube-training-worker2 sees 15 pod log dirs
```

## Exercises

1. **Move the zone agent.** Change `zone-a-agent`'s `nodeSelector` to
   `training/zone: zone-b`. What happens to the pod on `kube-training-worker`?
   *Hint:* `kubectl patch ds zone-a-agent -n lab-daemonsets -p '{"spec":{"template":{"spec":{"nodeSelector":{"training/zone":"zone-b"}}}}}'`.
   The old pod is deleted and a new one appears on `kube-training-worker2`.
   `NODE SELECTOR` now shows `training/zone=zone-b`.

2. **Roll back.** Return `node-agent` to `AGENT_VERSION=1.0` without editing
   any YAML.
   *Hint:* `kubectl rollout undo ds/node-agent -n lab-daemonsets --to-revision=1`,
   then check the logs. Note the warning about `last-applied-configuration`:
   the next `kubectl apply -f 01-...` could undo your undo.

3. **An agent for hardware you don't have (yet).** Create a DaemonSet that
   runs only on nodes labelled `training/gpu=true`. What does `kubectl get ds`
   show? On your own cluster, label a worker and watch the pod appear, then
   remove the label.
   *Hint:* `DESIRED 0` is perfectly valid. Solution:
   [`solutions/03-gpu-agent.yaml`](solutions/03-gpu-agent.yaml).

4. **Update one node at a time, by hand.** Create a DaemonSet with
   `updateStrategy: OnDelete`, change its template, and upgrade only the pod
   on `kube-training-worker`.
   *Hint:* `kubectl delete pod -n lab-daemonsets -l app=careful-agent --field-selector spec.nodeName=kube-training-worker`.
   `kubectl get ds` shows `UP-TO-DATE 1` of 2. Solution:
   [`solutions/04-careful-agent-ondelete.yaml`](solutions/04-careful-agent-ondelete.yaml).

5. **Tolerate everything.** Write a DaemonSet that runs on every node no
   matter what taints it has, like kube-proxy. Why is this right for kube-proxy
   and wrong for almost anything else?
   *Hint:* a toleration with just `operator: Exists`. Solution:
   [`solutions/05-tolerate-everything.yaml`](solutions/05-tolerate-everything.yaml).

6. **hostPort vs maxSurge.** Run an agent that serves metrics on each node's
   IP at port 19100 (`hostPort`), reach it from a pod via the node's
   InternalIP, then try a rolling update with `maxSurge: 1, maxUnavailable: 0`.
   What happens, and why?
   *Hint:* only one pod per node can bind a host port. Solution:
   [`solutions/06-hostport-agent.yaml`](solutions/06-hostport-agent.yaml).
   The surge pod stays `Pending` with
   `1 node(s) didn't have free ports for the requested pod ports`, and the
   rollout hangs until you go back to `maxSurge: 0, maxUnavailable: 1`
   (setting only `maxSurge: 0` is rejected: both can't be 0).

## Cleanup

```bash
kubectl delete namespace lab-daemonsets
```

Nothing in `kube-system` or on the nodes was changed. (If you labelled a node
in exercise 3, remove the label: `kubectl label node <node> training/gpu-`.)

## Further reading

* [DaemonSet](https://kubernetes.io/docs/concepts/workloads/controllers/daemonset/)
* [Perform a rolling update on a DaemonSet](https://kubernetes.io/docs/tasks/manage-daemon/update-daemon-set/)
* [Perform a rollback on a DaemonSet](https://kubernetes.io/docs/tasks/manage-daemon/rollback-daemon-set/)
* [Taints and tolerations](https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/)
* [Pod priority and preemption](https://kubernetes.io/docs/concepts/scheduling-eviction/pod-priority-preemption/) (`system-node-critical`)
