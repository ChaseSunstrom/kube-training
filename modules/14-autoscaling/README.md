# Module 14 – Autoscaling

## Goal

Make a Deployment scale **out and in by itself** with the
HorizontalPodAutoscaler, understand exactly how it decides, and know the other
autoscalers (vertical, in-place, cluster/node) and when to use which.

## What you'll learn

* metrics-server: what it is, installing it on kind (`--kubelet-insecure-tls`),
  `kubectl top`
* HPA `autoscaling/v2` on CPU utilization – and why it **needs requests**
* Multiple metrics (CPU + memory) and how the HPA combines them
* `behavior`: stabilization windows, scale-up/scale-down policies, tolerance
* Driving and watching scaling with a load generator and `kubectl get hpa -w`
* In-place pod resize (`kubectl patch --subresource resize`)
* Concepts: VerticalPodAutoscaler, Cluster Autoscaler, Karpenter, KEDA

## Concepts

### The autoscaling family

| What | Scales | Based on | Ships with Kubernetes? |
|---|---|---|---|
| **HorizontalPodAutoscaler** (HPA) | number of pods of a Deployment/StatefulSet/… | CPU/memory (metrics-server), custom or external metrics | yes (controller in kube-controller-manager) |
| **VerticalPodAutoscaler** (VPA) | requests/limits of pods | observed usage history | no – add-on from the `kubernetes/autoscaler` project |
| **In-place pod resize** | requests/limits of a *running* pod, without recreating it | whoever patches the `resize` subresource (you, VPA, an operator) | yes |
| **Cluster Autoscaler** | number of **nodes** in node groups | Pending pods that don't fit / under-used nodes | no – add-on, needs a cloud provider integration |
| **Karpenter** | **nodes**, provisioned just-in-time with a fitting instance type | Pending pods | no – add-on (AWS, Azure, …) |
| **KEDA** | pods (via an HPA it manages), including to/from zero | event sources (queues, Kafka lag, Prometheus, cron…) | no – CNCF add-on |

They work together: the HPA adds pods, the pods don't fit → they go Pending →
Cluster Autoscaler/Karpenter adds a node → the pods get scheduled
([module 10](../10-scheduling/README.md)). On a kind laptop cluster there are
no nodes to add, so this module concentrates on pods.

### Where the numbers come from

```
kubelet (cAdvisor/CRI stats on every node)
   │  /metrics/resource  (every node, HTTPS port 10250)
   ▼
metrics-server  (Deployment in kube-system, keeps only the latest values in memory)
   │  registers the API  metrics.k8s.io/v1beta1  (an APIService)
   ▼
kubectl top        HPA controller (every 15 s)
```

metrics-server is **not** a monitoring system – no history, no dashboards.
It only answers "how much CPU/memory does this pod/node use right now?". For
anything else use Prometheus (+ Prometheus Adapter or KEDA if you want to
autoscale on those metrics).

### The HPA algorithm

```
desiredReplicas = ceil( currentReplicas × currentMetricValue / targetValue )
```

* **CPU utilization** = average over the pods of `usage / request`. No CPU
  request → no utilization → the HPA can't work (Exercise 1).
* Ratios within the **tolerance** (default 10%) are ignored, so it doesn't flap
  around the target.
* Several metrics → one recommendation per metric → the **highest** wins.
* Not-yet-ready pods and pods with missing metrics are treated
  conservatively (assumed 0% when scaling up, 100% when scaling down).
* The result is clamped to `[minReplicas, maxReplicas]` and then shaped by
  `behavior`.

Example: 2 pods at 150% CPU, target 50% → `ceil(2 × 150 / 50) = 6`.

### `behavior` – how fast to move

| | Default scale-up | Default scale-down |
|---|---|---|
| `stabilizationWindowSeconds` | 0 (react immediately) | 300 (use the highest recommendation of the last 5 min) |
| `policies` | +100% **or** +4 pods per 15 s | −100% per 15 s |
| `selectPolicy` | `Max` (the policy allowing the biggest change) | `Max` |

The scale-down stabilization window is why an HPA keeps pods for 5 minutes
after load drops – on purpose, so a short dip doesn't throw away capacity
you'll need again in a second. `02-hpa-cpu.yaml` shortens it to 60 s for the
lab.

### Who owns `spec.replicas`?

Once an HPA targets a Deployment, the HPA writes `spec.replicas` (through the
`/scale` subresource). If your manifest also sets `replicas`, every
`kubectl apply` resets it, and the HPA corrects it again a moment later.
Remove `replicas` from manifests of autoscaled workloads – carefully,
see Exercise 3.

### Vertical scaling: VPA and in-place resize

**VPA** watches real usage and recommends (or applies) better requests. Its
modes: `Off` (only recommendations – a great way to right-size requests),
`Initial` (set requests when pods are created), `Recreate` (evict pods to
apply new values) and `InPlaceOrRecreate` (use in-place resize where
possible). Don't let VPA and HPA act on the **same** metric (e.g. both on
CPU) – they'd fight: VPA raises the request, utilization drops, HPA scales in…

**In-place pod resize** changes a running pod's requests/limits through the
pod's `resize` subresource; the kubelet updates the container's cgroup, and
`resizePolicy` decides per resource whether the container must restart. It
was beta (on by default) in Kubernetes 1.33 and is GA (stable, no feature
gate involved) on the 1.37 clusters this course targets. Rules worth knowing:
the QoS class can't change, a resize that doesn't fit the node is refused,
and a resize changes only **that pod** – not the Deployment's template.

## Files

| File | What it demonstrates |
|---|---|
| [`metrics-server/Kustomization`](metrics-server/Kustomization) | metrics-server v0.9.0 + `--kubelet-insecure-tls` for kind (`kubectl apply -k`) |
| [`00-namespace.yaml`](00-namespace.yaml) | The `lab-autoscaling` namespace |
| [`01-app.yaml`](01-app.yaml) | `web` Deployment (CPU **request** 50m) + Service |
| [`02-hpa-cpu.yaml`](02-hpa-cpu.yaml) | HPA v2 on 50% CPU utilization with tuned `behavior` |
| [`03-load-generator.yaml`](03-load-generator.yaml) | busybox `wget` loops that load `web` |
| [`04-hpa-cpu-memory.yaml`](04-hpa-cpu-memory.yaml) | Same HPA with CPU **and** memory metrics |
| [`05-resize-pod.yaml`](05-resize-pod.yaml) | Pod with `resizePolicy` for in-place resize |
| [`exercises/`](exercises/) / [`solutions/`](solutions/) | Exercises and reference answers |

## Lab

Run all commands from the repo root.

> **About the output shown here.** This module was tested on a cluster that
> could not pull the metrics-server image (an offline sandbox). The
> metrics-server install (step 1) was validated with a server-side dry run,
> and the outputs of `kubectl top` and of the HPA actually scaling (steps 2,
> 5, 6) are **examples** of what you will see, based on the load measured
> directly from the kubelet in step 4. Everything else is real output. On
> your laptop with internet access, all steps work as written.

### 1. Install metrics-server

```bash
kubectl kustomize modules/14-autoscaling/metrics-server | grep -A7 'args:'   # look before you apply
kubectl apply -k modules/14-autoscaling/metrics-server/
kubectl -n kube-system rollout status deployment metrics-server
kubectl get apiservice v1beta1.metrics.k8s.io
```

```
      - args:
        - --cert-dir=/tmp
        - --secure-port=10250
        - --kubelet-preferred-address-types=InternalIP,ExternalIP,Hostname
        - --kubelet-use-node-status-port
        - --metric-resolution=15s
        - --kubelet-insecure-tls
serviceaccount/metrics-server created
clusterrole.rbac.authorization.k8s.io/system:aggregated-metrics-reader created
clusterrole.rbac.authorization.k8s.io/system:metrics-server created
rolebinding.rbac.authorization.k8s.io/metrics-server-auth-reader created
clusterrolebinding.rbac.authorization.k8s.io/metrics-server:system:auth-delegator created
clusterrolebinding.rbac.authorization.k8s.io/system:metrics-server created
service/metrics-server created
deployment.apps/metrics-server created
apiservice.apiregistration.k8s.io/v1beta1.metrics.k8s.io created
```

The `Kustomization` pulls the pinned upstream release manifest and adds one
flag. Without `--kubelet-insecure-tls` the metrics-server pod typically runs
but never becomes Ready on kind, and its log shows TLS errors such as
`x509: cannot validate certificate for 172.18.0.x because it doesn't contain
any IP SANs` – kind's kubelets use self-signed serving certificates. The same change by hand, if you installed
the plain manifest:

```bash
kubectl -n kube-system patch deployment metrics-server --type=json \
  -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
```

`kubectl get apiservice v1beta1.metrics.k8s.io` should say
`AVAILABLE True` (give it ~30 s after the pod is Ready).

### 2. `kubectl top`

```bash
kubectl top nodes
kubectl top pods -A --sort-by=cpu | head
```

Example output:

```
NAME                          CPU(cores)   CPU(%)   MEMORY(bytes)   MEMORY(%)
kube-training-control-plane   180m         4%       780Mi           4%
kube-training-worker          45m          1%       310Mi           1%
kube-training-worker2         40m          1%       290Mi           1%
```

`CPU(%)` and `MEMORY(%)` are relative to the node's **allocatable**
resources. These are point-in-time values averaged over the last scrape
interval (15 s here), not history.

### 3. The app and an HPA

```bash
kubectl apply -f modules/14-autoscaling/00-namespace.yaml \
              -f modules/14-autoscaling/01-app.yaml \
              -f modules/14-autoscaling/02-hpa-cpu.yaml
kubectl -n lab-autoscaling rollout status deployment web
kubectl -n lab-autoscaling get hpa
```

Right after creation, before the first metrics arrive, and **forever if
metrics-server is missing**, you see `<unknown>`. This is real output from a
cluster without metrics-server – worth recognising:

```
NAME   REFERENCE        TARGETS              MINPODS   MAXPODS   REPLICAS   AGE
web    Deployment/web   cpu: <unknown>/50%   1         6         1          2s
```

```bash
kubectl -n lab-autoscaling describe hpa web | sed -n '/^Conditions/,$p'
```

```
Conditions:
  Type           Status  Reason                   Message
  ----           ------  ------                   -------
  AbleToScale    True    SucceededGetScale        the HPA controller was able to get the target's current scale
  ScalingActive  False   FailedGetResourceMetric  the HPA was unable to compute the replica count: failed to get
                 cpu utilization: unable to get metrics for resource cpu: unable to fetch metrics from resource
                 metrics API: the server could not find the requested resource (get pods.metrics.k8s.io)
Events:
  Type     Reason                        Age   From                       Message
  ----     ------                        ----  ----                       -------
  Warning  FailedGetResourceMetric       2s    horizontal-pod-autoscaler  failed to get cpu utilization: ...
  Warning  FailedComputeMetricsReplicas  2s    horizontal-pod-autoscaler  invalid metrics (1 invalid out of 1), ...
```

`the server could not find the requested resource (get pods.metrics.k8s.io)`
= the metrics API isn't registered → install metrics-server (step 1). With
metrics-server running, after 15–60 s the target becomes a number, e.g.
`cpu: 1%/50%`, and `ScalingActive` turns `True`.

### 4. Generate load (and peek at the raw numbers)

Open a second terminal and watch the HPA:

```bash
kubectl -n lab-autoscaling get hpa web -w
```

In the first terminal, start the load:

```bash
kubectl apply -f modules/14-autoscaling/03-load-generator.yaml
```

Curious where the CPU numbers come from? metrics-server reads the kubelet's
`/metrics/resource` endpoint – you can too, through the API server's node
proxy (this works even without metrics-server):

```bash
POD=$(kubectl -n lab-autoscaling get pods -l app=web -o jsonpath='{.items[0].metadata.name}')
NODE=$(kubectl -n lab-autoscaling get pod "$POD" -o jsonpath='{.spec.nodeName}')
kubectl get --raw "/api/v1/nodes/$NODE/proxy/metrics/resource" | grep "^container_cpu_usage_seconds_total.*pod=\"$POD\""
```

Run the last command twice, ~20 s apart:

```
container_cpu_usage_seconds_total{container="whoami",namespace="lab-autoscaling",pod="web-6978847c57-vvkvb"} 2.04463387 1791458260622
container_cpu_usage_seconds_total{container="whoami",namespace="lab-autoscaling",pod="web-6978847c57-vvkvb"} 3.759296574 1791458271752
```

The value is a counter of CPU-seconds used so far; the last number is the
sample's timestamp in milliseconds. (3.759 − 2.045) s of CPU in
(271.752 − 260.622) s ≈ 1.71 / 11.13 ≈ **0.154 cores = 154m** – about **300%**
of the pod's 50m request, far above the 50% target. metrics-server does
exactly this calculation for every container.

### 5. Watch it scale out

The watch in terminal 2 will look like this (example – timing and numbers vary
with your machine):

```
NAME   REFERENCE        TARGETS        MINPODS   MAXPODS   REPLICAS   AGE
web    Deployment/web   cpu: 1%/50%    1         6         1          2m
web    Deployment/web   cpu: 308%/50%  1         6         1          2m15s
web    Deployment/web   cpu: 308%/50%  1         6         3          2m30s
web    Deployment/web   cpu: 110%/50%  1         6         6          2m45s
web    Deployment/web   cpu: 52%/50%   1         6         6          3m30s
```

How to read it:

* 308% with target 50% → the formula wants `ceil(1 × 308/50) = 7`, capped
  at `maxReplicas` 6, but
  `behavior.scaleUp` allows at most "+100% or +2 pods" per 15 s →
  1 → 3 → 6.
* With 6 pods the same load is spread out and the average drops towards the
  target. It won't go above 6 (`maxReplicas`) even if utilization stays high
  – check `describe hpa`: condition `ScalingLimited True TooManyReplicas`.

```bash
kubectl -n lab-autoscaling get deployment web
kubectl -n lab-autoscaling describe hpa web | sed -n '/^Events/,$p'
```

The events show lines like `New size: 3; reason: cpu resource utilization
(percentage of request) above target`.

### 6. Stop the load and watch it scale in

```bash
kubectl -n lab-autoscaling scale deployment load-generator --replicas=0
```

Utilization falls to ~1% within a minute, but the replica count doesn't drop
immediately: the HPA first waits for the 60 s stabilization window, then the
scale-down policy removes **one pod every 30 s** (6 → 5 → … → 1, ~3–4 min in
total). With the default behavior (300 s window, −100% per 15 s) it would wait
five minutes and then drop straight to 1.

### 7. Two metrics: CPU and memory

```bash
kubectl apply -f modules/14-autoscaling/04-hpa-cpu-memory.yaml
kubectl -n lab-autoscaling get hpa web
```

```
NAME   REFERENCE        TARGETS                                      MINPODS   MAXPODS   REPLICAS   AGE
web    Deployment/web   cpu: <unknown>/50%, memory: <unknown>/40Mi   1         6         1          114s
```

(Real output without metrics-server; with it you'll see e.g.
`cpu: 1%/50%, memory: 9Mi/40Mi`.) The HPA computes a replica count for each
metric and takes the largest; it only scales in when **all** metrics allow it.
whoami uses far less than 40Mi, so here memory never drives scaling – and
that's typical: memory is a poor scaling signal for most runtimes.

### 8. In-place pod resize

```bash
kubectl apply -f modules/14-autoscaling/05-resize-pod.yaml
kubectl -n lab-autoscaling wait --for=condition=Ready pod/resize-demo
kubectl -n lab-autoscaling exec resize-demo -- cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us 2>/dev/null \
  || kubectl -n lab-autoscaling exec resize-demo -- cat /sys/fs/cgroup/cpu.max
```

```
20000
```

A CPU limit of 200m = 20 ms of CPU time per 100 ms period (on cgroup v2
hosts you see `20000 100000` from `cpu.max`). Now double the CPU, through the
`resize` subresource:

```bash
kubectl -n lab-autoscaling patch pod resize-demo --subresource resize --patch \
  '{"spec":{"containers":[{"name":"app","resources":{"requests":{"cpu":"200m"},"limits":{"cpu":"400m"}}}]}}'
kubectl -n lab-autoscaling get pod resize-demo \
  -o jsonpath='{.status.containerStatuses[0].resources}{"\n"}restarts={.status.containerStatuses[0].restartCount}{"\n"}'
kubectl -n lab-autoscaling exec resize-demo -- cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us 2>/dev/null \
  || kubectl -n lab-autoscaling exec resize-demo -- cat /sys/fs/cgroup/cpu.max
```

```
pod/resize-demo patched
{"limits":{"cpu":"400m","memory":"64Mi"},"requests":{"cpu":"200m","memory":"32Mi"}}
restarts=0
40000
```

`status.containerStatuses[].resources` shows what's **actually** applied
(`spec` shows what you asked for); the cgroup quota doubled and the container
did **not** restart (`resizePolicy: cpu NotRequired`). Now memory, whose
policy is `RestartContainer`:

```bash
kubectl -n lab-autoscaling patch pod resize-demo --subresource resize --patch \
  '{"spec":{"containers":[{"name":"app","resources":{"requests":{"memory":"64Mi"},"limits":{"memory":"128Mi"}}}]}}'
kubectl -n lab-autoscaling get pod resize-demo
kubectl -n lab-autoscaling get events --field-selector involvedObject.name=resize-demo
```

```
NAME          READY   STATUS    RESTARTS     AGE
resize-demo   1/1     Running   1 (0s ago)   16s

... Normal   ResizeStarted     pod/resize-demo   Pod resize started: {"containers":[{"name":"app","resources":{"limits":{"cpu":"400m","memory":"128Mi"},...
... Normal   Killing           pod/resize-demo   Container app resize requires restart
... Normal   ResizeCompleted   pod/resize-demo   Pod resize completed: ...
```

Same pod (same name, same IP), but the container was restarted to apply the
memory change. Two ways to get it wrong:

```bash
# 1. Without --subresource resize, resources are immutable as always:
kubectl -n lab-autoscaling patch pod resize-demo \
  -p '{"spec":{"containers":[{"name":"app","resources":{"requests":{"cpu":"300m"}}}]}}'
# The Pod "resize-demo" is invalid: spec: Forbidden: pod updates may not change fields other than ...

# 2. Asking for more than the node can ever offer:
kubectl -n lab-autoscaling patch pod resize-demo --subresource resize --patch \
  '{"spec":{"containers":[{"name":"app","resources":{"requests":{"cpu":"20"},"limits":{"cpu":"20"}}}]}}'
# Error from server (Forbidden): pods "resize-demo" is forbidden: node didn't have enough allocatable
# resources: cpu, requested: 20000, allocatable: 4000
```

(The allocatable value depends on your machine.) A resize that would fit the
node in principle but not right now is accepted and stays pending – the pod's
`PodResizePending` condition tells you why. Also note: after a resize, re-applying
`05-resize-pod.yaml` fails with the same "pod updates may not change fields"
error, because the file's resources no longer match the pod.

## Exercises

1. **The HPA that never scales.** Apply
   [`exercises/01-no-request.yaml`](exercises/01-no-request.yaml) (with
   metrics-server running). Why does TARGETS stay `<unknown>`? Look at the
   pod's `resources` with `kubectl get pod -o yaml` – where did the memory
   request come from? Fix it.
   *Hint:* `describe hpa` → `missing request for cpu`.
   Solution: [`solutions/01-with-request.yaml`](solutions/01-with-request.yaml).

2. **A cautious HPA.** Change the `web` HPA so that it adds at most one pod
   every 30 s (and only after the higher recommendation has held for 30 s),
   waits 2 minutes before scaling in, then removes at most half the pods per
   minute, and ignores deviations below 5%. Rerun steps 4–6 and compare.
   Solution: [`solutions/02-hpa-cautious.yaml`](solutions/02-hpa-cautious.yaml).

3. **Who owns replicas?** While the HPA has scaled `web` to several pods,
   run `kubectl apply -f modules/14-autoscaling/01-app.yaml` and watch
   `kubectl -n lab-autoscaling get deploy web -w`. What happens, and why does
   the HPA undo it? Remove `replicas` from the manifest **without** the
   Deployment ever dropping to one pod.
   *Hint:* simply deleting the line and applying drops it to 1 once (the
   field disappears from the object and is defaulted). Look at
   `kubectl apply set-last-applied` and at `kubectl apply --server-side`.
   Solution: [`solutions/03-web-without-replicas.yaml`](solutions/03-web-without-replicas.yaml)
   (both variants tested).

4. **Do the maths.** Without running anything: (a) 3 pods at 80% CPU,
   target 50% – desired replicas? (b) 4 pods at 53%, target 50%? (c) 2 pods,
   CPU at 30% of target 50% and memory at 90Mi with target 40Mi average –
   what does the HPA do? Then check (a) on the cluster by tuning the load
   generator's replicas.
   *Answers:* (a) `ceil(3 × 80/50) = ceil(4.8) = 5`; (b) ratio 1.06 is within
   the 10% tolerance → stays at 4; (c) CPU says `ceil(2 × 30/50) = 2`, memory
   says `ceil(2 × 90/40) = 5` → the higher one wins: 5.

5. **Resize is per pod.** Resize one `web` pod in place to a 100m CPU request
   (`kubectl -n lab-autoscaling patch pod <web-pod> --subresource resize ...`,
   container name `whoami`). Then delete that pod. What resources does the
   replacement get, and why? What would you change to make it permanent?
   *Answer:* the replacement comes from the Deployment's template, so it's
   back to 50m. Change the template (rolling update) – or let a VPA in
   `InPlaceOrRecreate` mode manage it.

## Cleanup

```bash
kubectl delete namespace lab-autoscaling
# metrics-server is a cluster add-on; later modules (e.g. the capstone) use it.
# To remove it anyway:
kubectl delete -k modules/14-autoscaling/metrics-server/
```

## Further reading

* [Horizontal Pod Autoscaling](https://kubernetes.io/docs/concepts/workloads/autoscaling/horizontal-pod-autoscale/)
* [HorizontalPodAutoscaler Walkthrough](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale-walkthrough/)
* [Autoscaling Workloads](https://kubernetes.io/docs/concepts/workloads/autoscaling/) – HPA, VPA, event-driven
* [Resource metrics pipeline](https://kubernetes.io/docs/tasks/debug/debug-cluster/resource-metrics-pipeline/)
* [Resize CPU and Memory Resources assigned to Containers](https://kubernetes.io/docs/tasks/configure-pod-container/resize-container-resources/)
* [Node autoscaling](https://kubernetes.io/docs/concepts/cluster-administration/node-autoscaling/) – Cluster Autoscaler, Karpenter
* [metrics-server](https://github.com/kubernetes-sigs/metrics-server) · [VPA](https://github.com/kubernetes/autoscaler/tree/master/vertical-pod-autoscaler) · [KEDA](https://keda.sh/)
