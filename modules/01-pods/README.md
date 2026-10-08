# 01 – Pods

## Goal

Understand the pod – the unit everything else in Kubernetes is built from –
well enough to predict how it starts, runs, fails, restarts and stops.

## What you'll learn

* What a pod is, its lifecycle **phases**, container **states** and pod **conditions**
* `restartPolicy` (`Always`, `OnFailure`, `Never`) and `CrashLoopBackOff`
* Environment variables and the **Downward API** (pod name, IP, node, labels, limits)
* How `command`/`args` override an image's `ENTRYPOINT`/`CMD`
* Multi-container pods sharing an `emptyDir` volume and `localhost`
* **Init containers** and **native sidecar containers** (`initContainers[].restartPolicy: Always`)
* **Startup, liveness and readiness probes** – and what happens when each one fails
* **Requests and limits**, the three **QoS classes**, and an **OOMKilled** container
* **Graceful termination**: `preStop`, SIGTERM, `terminationGracePeriodSeconds`

## Concepts

### What a pod is

A pod is one or more containers that are always scheduled **together on the
same node** and share:

* a **network namespace** – one IP address; containers talk to each other on `localhost` and must not use the same port;
* **volumes** that they mount (each container chooses where);
* a lifecycle – the pod is created, scheduled and deleted as one unit.

Each container still has its own image, filesystem, process tree and
resource limits. Pods are **disposable**: a pod is never "moved" to another
node or "resurrected". Controllers (Deployments, StatefulSets, Jobs – modules
03, 07, 08) create *new* pods to replace lost ones. Containers inside a pod,
however, can be **restarted in place** by the kubelet.

### Phases, container states and conditions

`kubectl get pods` shows a STATUS column that mixes several things. The real
fields are:

| `status.phase` | Meaning |
|---|---|
| `Pending` | Accepted by the API server, but not all containers are running yet: waiting for a node, pulling images, or running init containers |
| `Running` | Bound to a node, all containers created, at least one is running (or restarting) |
| `Succeeded` | All containers exited 0 and will not be restarted |
| `Failed` | All containers have terminated, at least one with a non-zero exit code (or the pod was evicted) |
| `Unknown` | The node stopped reporting (usually it is down or partitioned) |

Each **container** is in one of three states: `Waiting` (with a reason such
as `ContainerCreating`, `ImagePullBackOff`, `CrashLoopBackOff`), `Running`, or
`Terminated` (with a reason such as `Completed`, `Error`, `OOMKilled` and an
exit code). `lastState` keeps the previous termination – that is where you
find *why* a container restarted.

**Conditions** are true/false checkpoints: `PodScheduled` →
`PodReadyToStartContainers` (sandbox + network ready) → `Initialized` (init
containers done) → `ContainersReady` → `Ready` (the pod may receive Service
traffic).

The STATUS column shows the most interesting of these: e.g. `Init:1/2`,
`PodInitializing`, `CrashLoopBackOff`, `OOMKilled`, `Completed`, `Error`,
`Terminating` (the latter is not a phase at all – it means
`metadata.deletionTimestamp` is set).

### restartPolicy

Pod-level, applies to all regular containers (a container *can* override it
with its own `restartPolicy`/`restartPolicyRules` – a newer feature, beta and
on by default in 1.37, not used in this course):

| restartPolicy | Container exits 0 | Container exits non-zero | Pod can end as |
|---|---|---|---|
| `Always` (default) | restart | restart | never ends (stays `Running`) |
| `OnFailure` | done | restart | `Succeeded` |
| `Never` | done | done | `Succeeded` or `Failed` |

The first restart is immediate; after that the kubelet backs off
exponentially (10s, 20s, 40s … capped at 5 min, reset after 10 minutes of
running fine). While the kubelet waits, the container is
`Waiting` with reason `CrashLoopBackOff`. CrashLoopBackOff is not an error in
itself – it is the kubelet *pacing* restarts of a container that keeps exiting.

### Probes

| Probe | Question | On failure | Typical check |
|---|---|---|---|
| **startup** | Has the app finished starting? Liveness and readiness wait for it. | restart after `failureThreshold` × `periodSeconds` | same endpoint as liveness, with a generous threshold |
| **liveness** | Is the process hopelessly stuck? | **restart the container** | cheap, local: "can I answer at all?" |
| **readiness** | Should this pod receive traffic right now? | **mark NotReady**, remove from Service endpoints; no restart | "are my dependencies/caches ready?" |

Mechanisms: `httpGet` (status 200–399), `tcpSocket`, `exec` (exit 0), `grpc`.
Classic mistakes: a liveness probe that checks a database (one DB blip
restarts every replica), or no readiness probe (traffic hits pods that are
still starting).

### Requests, limits and QoS

* **requests** – what the **scheduler** reserves. A node fits a pod only if `allocatable − sum(requests of pods already there) ≥ pod requests`. Actual usage does not matter for scheduling.
* **limits** – what the **kernel** enforces. CPU above the limit is **throttled**; memory above the limit gets the container **OOM-killed**.

| QoS class | Rule | Under node memory pressure |
|---|---|---|
| `Guaranteed` | every container (init containers too) has CPU **and** memory limits, with requests = limits for both | evicted last |
| `Burstable` | anything in between | evicted after BestEffort, roughly by how far usage exceeds requests |
| `BestEffort` | no requests or limits on any container | evicted first |

The "evicted first/last" column is the usual rule of thumb. Precisely, the
kubelet ranks pods by (1) whether their usage exceeds their requests, (2) pod
priority, then (3) how far usage exceeds requests — which works out to the
QoS order above in practice, since BestEffort pods have no requests at all
and Guaranteed pods can't exceed theirs.

### What happens on delete

```
kubectl delete pod X
  │  API server sets deletionTimestamp ─► pod shows "Terminating"
  │                                     ─► EndpointSlice controller removes it from Services
  ▼
kubelet: run preStop hook (if any)        ┐
kubelet: send SIGTERM to PID 1 of each    │ all within terminationGracePeriodSeconds
         container                        │ (default 30s)
container cleans up and exits             ┘
  ...still running at the deadline? ─► SIGKILL
```

PID 1 in a container gets **no default signal handling**: if your process does
not install a SIGTERM handler, SIGTERM does nothing and every delete takes the
full grace period. That is why shells in this repo use
`trap 'exit 0' TERM; sleep infinity & wait`.

## Files

| File | What it demonstrates |
|---|---|
| [`00-namespace.yaml`](00-namespace.yaml) | The `lab-pods` namespace |
| [`01-basic-pod.yaml`](01-basic-pod.yaml) | A single-container nginx pod; phases and conditions |
| [`02-pending-pod.yaml`](02-pending-pod.yaml) | A pod that can never be scheduled (`Pending`, `FailedScheduling`) |
| [`03-restart-policies.yaml`](03-restart-policies.yaml) | `Always` / `OnFailure` / `Never` side by side → `Running`+`CrashLoopBackOff`, `Succeeded`, `Failed` |
| [`04-env-downward-api.yaml`](04-env-downward-api.yaml) | Env vars, `$(VAR)` expansion, Downward API as env vars and as a volume |
| [`05-command-args.yaml`](05-command-args.yaml) | `args` keeping the image ENTRYPOINT; `command` + `args` replacing it |
| [`06-multi-container.yaml`](06-multi-container.yaml) | Two containers sharing an `emptyDir` and `localhost` |
| [`07-init-containers.yaml`](07-init-containers.yaml) | Two init containers: render config, then wait for a dependency |
| [`08-init-dependency-service.yaml`](08-init-dependency-service.yaml) | The Service that unblocks the init container in 07 |
| [`09-native-sidecar.yaml`](09-native-sidecar.yaml) | A native sidecar log shipper in a run-to-completion pod |
| [`10-probes.yaml`](10-probes.yaml) | Startup + liveness + readiness on a healthy nginx; toggling readiness |
| [`11-liveness-fail.yaml`](11-liveness-fail.yaml) | A liveness probe that deliberately starts failing → restarts |
| [`12-qos-classes.yaml`](12-qos-classes.yaml) | Guaranteed, Burstable and BestEffort pods |
| [`13-oomkilled.yaml`](13-oomkilled.yaml) | A container exceeding its memory limit → `OOMKilled`, exit code 137 |
| [`14-graceful-termination.yaml`](14-graceful-termination.yaml) | `preStop` + SIGTERM handler (fast, clean) vs. a process that ignores SIGTERM |
| [`exercises/`](exercises/) | Broken/incomplete manifests for the exercises |
| [`solutions/`](solutions/) | Reference answers |

## Lab

Keep a second terminal open with a watch running – it is the best way to
*see* the lifecycle:

```bash
kubectl get pods -n lab-pods -w
```

### 1. A basic pod and its lifecycle

```bash
kubectl apply -f modules/01-pods/00-namespace.yaml
kubectl apply -f modules/01-pods/01-basic-pod.yaml
```

The watch shows the phases go by:

```
NAME   READY   STATUS              RESTARTS   AGE
web    0/1     Pending             0          0s
web    0/1     ContainerCreating   0          0s
web    1/1     Running             0          2s
```

`Pending` → the scheduler picks a node; `ContainerCreating` (still phase
`Pending`) → the kubelet creates the pod sandbox, the CNI assigns an IP, the
image is pulled; `Running` → the container process started.

```bash
kubectl describe pod web -n lab-pods          # read Conditions and Events
kubectl get pod web -n lab-pods -o jsonpath='{range .status.conditions[*]}{.type}={.status}{"\n"}{end}'
```

```
PodReadyToStartContainers=True
Initialized=True
Ready=True
ContainersReady=True
PodScheduled=True
```

### 2. A pod stuck in Pending

```bash
kubectl apply -f modules/01-pods/02-pending-pod.yaml
kubectl get pod too-big -n lab-pods
kubectl describe pod too-big -n lab-pods | tail -3
```

```
NAME      READY   STATUS    RESTARTS   AGE
too-big   0/1     Pending   0          1s

  Warning  FailedScheduling  2s  default-scheduler  0/3 nodes are available: 1 node(s) had untolerated
  taint(s), 2 Insufficient cpu. preemption: 0/3 nodes are available: 3 Preemption is not helpful for scheduling.
```

Read the message like the scheduler does: of 3 nodes, the control plane is
excluded by its taint and the 2 workers do not have 64 CPUs of *allocatable*
capacity. Kubernetes never "partially" schedules a pod – it waits until a node
fits. Delete it, it will never run:

```bash
kubectl delete pod too-big -n lab-pods
```

### 3. restartPolicy in action

```bash
kubectl apply -f modules/01-pods/03-restart-policies.yaml
```

Within a few seconds:

```
NAME           READY   STATUS      RESTARTS      AGE
rp-always      1/1     Running     0             3s
rp-never       0/1     Error       0             4s
rp-onfailure   1/1     Running     1 (2s ago)    4s
rp-onfailure   0/1     Completed   1 (3s ago)    5s
```

and after a minute or two:

```
NAME           READY   STATUS             RESTARTS      AGE
rp-always      0/1     CrashLoopBackOff   3 (31s ago)   63s
rp-never       0/1     Error              0             63s
rp-onfailure   0/1     Completed          1             63s
```

```bash
kubectl get pods -n lab-pods -l app=restart-demo \
  -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,RESTARTS:.status.containerStatuses[0].restartCount
```

```
NAME           PHASE       RESTARTS
rp-always      Running     3
rp-never       Failed      0
rp-onfailure   Succeeded   1
```

* **rp-always** exits with code **0** every time and is still restarted:
  `Always` means always. Its phase stays `Running` even though it is mostly
  waiting – a `Deployment` pod that "completes" looks exactly like this.
  Look at the container that just exited with `--previous`:
  ```bash
  kubectl logs rp-always -n lab-pods --previous
  kubectl describe pod rp-always -n lab-pods | grep -A4 'Last State'
  ```
  ```
  started
  done, exiting 0
      Last State:     Terminated
        Reason:       Completed
        Exit Code:    0
  ```
* **rp-onfailure** failed once, was restarted, then succeeded. It knew it
  had already tried because the marker file lives in an `emptyDir`, which
  belongs to the **pod** and survives container restarts.
* **rp-never** failed with exit code 3 and stays `Failed`. Its logs are kept
  until you delete the pod: `kubectl logs rp-never -n lab-pods`.

Clean up the crash-looping one: `kubectl delete -f modules/01-pods/03-restart-policies.yaml`.

### 4. Environment variables and the Downward API

```bash
kubectl apply -f modules/01-pods/04-env-downward-api.yaml
kubectl logs env-demo -n lab-pods
```

```
I am env-demo in namespace lab-pods
my IP is 10.244.1.115, I run on node kube-training-worker2 as serviceaccount default
memory limit: 32 MiB, cpu request: 5 millicores
GREETING=hello
BANNER=hello from env-demo
```

`BANNER` was built by Kubernetes from `$(GREETING) from $(POD_NAME)` – a
reference to variables defined *earlier* in the same `env` list. Now see the
difference between env vars and the downward API *volume*:

```bash
kubectl exec env-demo -n lab-pods -- cat /etc/podinfo/labels
kubectl label pod env-demo -n lab-pods tier=frontend --overwrite
kubectl exec env-demo -n lab-pods -- cat /etc/podinfo/labels   # repeat until it changes (seconds to ~1 min)
```

```
app="env-demo"
tier="frontend"
```

The file is updated by the kubelet; environment variables are fixed when the
process starts and can never change in a running container.

### 5. command and args vs ENTRYPOINT and CMD

```bash
kubectl apply -f modules/01-pods/05-command-args.yaml
kubectl logs args-only -n lab-pods
kubectl logs command-and-args -n lab-pods
```

```
2026/10/08 10:20:45 [INFO] server is listening on :8080

1. hi was expanded by Kubernetes before the shell ran
2. hi was expanded by the shell at runtime
3. not expanded by anyone: $(GREETING)
4. my hostname is command-and-args
```

* `args-only` set only `args`, so the image's `ENTRYPOINT` (`/http-echo`)
  still runs, now with our flags. Check it answers:
  `kubectl exec web -n lab-pods -- wget -qO- http://$(kubectl get pod args-only -n lab-pods -o jsonpath='{.status.podIP}'):8080`
  → `hello from args-only`.
* `command-and-args` replaced the entrypoint with `sh -c` and passed a script
  as the argument. Line 1 vs line 2 shows *who* expands variables:
  `$(VAR)` is expanded by Kubernetes (only for vars defined in the container
  spec), `$VAR` by the shell (any env var, including `HOSTNAME`). Without a
  shell in `command`, `$VAR` is just text.

### 6. Two containers, one volume, one IP

```bash
kubectl apply -f modules/01-pods/06-multi-container.yaml
kubectl get pod shared-volume -n lab-pods                   # READY 2/2
kubectl logs shared-volume -n lab-pods -c writer
kubectl exec shared-volume -n lab-pods -c web -- wget -qO- http://localhost/
```

```
<p>Thu Oct  8 10:21:24 UTC 2026 - written by the writer container</p>
<p>Thu Oct  8 10:21:29 UTC 2026 - written by the writer container</p>
<p>Thu Oct  8 10:21:34 UTC 2026 - written by the writer container</p>
```

The writer appends to `/html/index.html`; nginx serves the same volume from
`/usr/share/nginx/html`. Now ask from the **writer** container, which has no
web server at all:

```bash
kubectl exec shared-volume -n lab-pods -c writer -- wget -qO- http://localhost/ | tail -1
```

It works: both containers share one network namespace, so `localhost:80` in
the writer *is* nginx. Without `-c`, `kubectl logs`/`exec` pick the first
container and print `Defaulted container "web" out of: web, writer`. To see
everything: `kubectl logs shared-volume -n lab-pods --all-containers --prefix`.

### 7. Init containers

```bash
kubectl apply -f modules/01-pods/07-init-containers.yaml
kubectl get pod init-demo -n lab-pods
kubectl logs init-demo -n lab-pods -c render-config
kubectl logs init-demo -n lab-pods -c wait-for-db
```

```
NAME        READY   STATUS     RESTARTS   AGE
init-demo   0/1     Init:1/2   0          3s
config rendered
waiting for init-demo-db...
waiting for init-demo-db...
```

`Init:1/2`: the first init container finished, the second is looping. The
app container (nginx) has not even been created. Create the dependency:

```bash
kubectl apply -f modules/01-pods/08-init-dependency-service.yaml
kubectl get pod init-demo -n lab-pods -w        # Init:1/2 -> PodInitializing -> Running
kubectl exec init-demo -n lab-pods -- wget -qO- http://localhost/
```

```
<h1>rendered by an init container at Thu Oct  8 10:21:55 UTC 2026</h1>
```

Init containers ran **in order, to completion**, and left their result in a
shared volume for the app:

```bash
kubectl get pod init-demo -n lab-pods \
  -o jsonpath='{range .status.initContainerStatuses[*]}{.name}: {.state.terminated.reason} exit={.state.terminated.exitCode}{"\n"}{end}'
```

```
render-config: Completed exit=0
wait-for-db: Completed exit=0
```

> **Ordering across pods** (pod B must start only after pod A, e.g. both
> using one ReadWriteOnce volume) is a classic real-world problem with several
> wrong answers. See [`scenarios/rwo-pvc-ordered-pods`](../../scenarios/rwo-pvc-ordered-pods/README.md).

### 8. Native sidecar containers

```bash
kubectl apply -f modules/01-pods/09-native-sidecar.yaml
kubectl get pod sidecar-demo -n lab-pods -w
```

```
NAME           READY   STATUS            RESTARTS   AGE
sidecar-demo   0/2     Init:0/1          0          0s
sidecar-demo   0/2     PodInitializing   0          3s
sidecar-demo   1/2     PodInitializing   0          3s
sidecar-demo   2/2     Running           0          4s
sidecar-demo   1/2     Completed         0          15s
sidecar-demo   0/2     Completed         0          16s
```

```bash
kubectl logs sidecar-demo -n lab-pods -c log-shipper
```

```
[shipper] started, tailing app.log
[shipped] processing item 1
...
[shipped] all items processed
[shipper] got SIGTERM, flushing and exiting
```

What happened:

1. `log-shipper` is listed under `initContainers`, so it started first – but
   because of `restartPolicy: Always` the kubelet only waited for its
   **startupProbe** to pass, not for it to exit (`Init:0/1` → `PodInitializing`).
2. `app` then started; both ran side by side (`2/2 Running`).
3. When `app` exited, the kubelet sent SIGTERM to the sidecar and the pod
   became `Completed` (phase `Succeeded`).

With a classic sidecar (a second entry in `containers`) step 3 never
happens and the pod runs forever – try it in exercise 3. Native sidecars are
GA since Kubernetes 1.33 and are what service meshes and log agents now use.

### 9. Probes on a healthy app

```bash
kubectl apply -f modules/01-pods/10-probes.yaml
kubectl get pod probes-demo -n lab-pods          # 1/1 Running
```

Break **readiness** only – remove the page the readiness probe fetches:

```bash
kubectl exec probes-demo -n lab-pods -- rm /usr/share/nginx/html/index.html
kubectl get pod probes-demo -n lab-pods
kubectl describe pod probes-demo -n lab-pods | grep Unhealthy
```

```
NAME          READY   STATUS    RESTARTS   AGE
probes-demo   0/1     Running   0          7s
  Warning  Unhealthy  1s (x2 over 1s)  kubelet  spec.containers{nginx}: Readiness probe failed: HTTP probe failed with statuscode: 404
```

`READY 0/1`, but `RESTARTS 0`: a failing readiness probe never restarts
anything. If this pod were behind a Service it would simply stop receiving
traffic (you will watch that happen in module 04). The liveness probe only
checks that port 80 accepts connections, which it still does. Fix it:

```bash
kubectl exec probes-demo -n lab-pods -- sh -c 'echo back > /usr/share/nginx/html/index.html'
kubectl get pod probes-demo -n lab-pods          # 1/1 again within ~3s
```

### 10. A liveness probe that fails on purpose

```bash
kubectl apply -f modules/01-pods/11-liveness-fail.yaml
kubectl get pod liveness-fail -n lab-pods -w
```

After about 35 seconds (20s healthy + 3 failed probes 5s apart) RESTARTS
goes to 1, then keeps climbing; after a few rounds the kubelet adds a
back-off delay between restarts.

```bash
kubectl describe pod liveness-fail -n lab-pods | grep -A12 '^Events'
```

```
  Normal   Scheduled  73s               default-scheduler  Successfully assigned lab-pods/liveness-fail to kube-training-worker2
  Normal   Created    2s (x3 over 71s)  kubelet            spec.containers{app}: Container created
  Warning  Unhealthy  2s (x6 over 47s)  kubelet            spec.containers{app}: Liveness probe failed: cat: can't open '/tmp/healthy': No such file or directory
  Normal   Killing    2s (x2 over 37s)  kubelet            spec.containers{app}: Container app failed liveness probe, will be restarted
  Normal   Started    1s (x3 over 70s)  kubelet            spec.containers{app}: Container started
```

```bash
kubectl logs liveness-fail -n lab-pods --previous
```

```
healthy
now pretending to be stuck
got SIGTERM from the kubelet
```

A liveness kill is a normal graceful stop: SIGTERM first (our trap printed a
message and exited 143 = 128 + 15), SIGKILL only after the grace period.
`describe` shows `Last State: Terminated, Reason: Error, Exit Code: 143`.
Delete it before it gets annoying: `kubectl delete pod liveness-fail -n lab-pods`.

### 11. Requests, limits and QoS classes

```bash
kubectl apply -f modules/01-pods/12-qos-classes.yaml
kubectl get pods -n lab-pods -l app=qos-demo \
  -o custom-columns=NAME:.metadata.name,QOS:.status.qosClass,CPU_REQ:.spec.containers[0].resources.requests.cpu,MEM_LIM:.spec.containers[0].resources.limits.memory
kubectl get pod qos-guaranteed -n lab-pods -o jsonpath='{.status.qosClass}{"\n"}'
```

```
NAME             QOS          CPU_REQ   MEM_LIM
qos-besteffort   BestEffort   <none>    <none>
qos-burstable    Burstable    10m       64Mi
qos-guaranteed   Guaranteed   50m       32Mi
Guaranteed
```

See what the scheduler has reserved on a node (sum of *requests*, not usage):

```bash
kubectl describe node kube-training-worker | sed -n '/Allocated resources/,/Events/p'
```

```
  Resource           Requests    Limits
  --------           --------    ------
  cpu                420m (10%)  1900m (47%)
  memory             546Mi (3%)  1154Mi (7%)
```

Limits can add up to more than 100 % ("overcommitted"); requests cannot.
(Real CPU/memory *usage* needs metrics-server – `kubectl top`, module 14.)

### 12. OOMKilled

```bash
kubectl apply -f modules/01-pods/13-oomkilled.yaml
kubectl get pod oom-demo -n lab-pods -w
```

The watch shows `OOMKilled` and, after a couple of rounds, `CrashLoopBackOff`:

```bash
kubectl get pod oom-demo -n lab-pods \
  -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason} {.status.containerStatuses[0].lastState.terminated.exitCode}{"\n"}'
kubectl describe pod oom-demo -n lab-pods | sed -n '/State:/,/Restart Count/p'
```

```
OOMKilled 137
    State:          Waiting
      Reason:       CrashLoopBackOff
    Last State:     Terminated
      Reason:       OOMKilled
      Exit Code:    137
    Ready:          False
    Restart Count:  2
```

Exit code 137 = 128 + 9: killed by SIGKILL, from the kernel, with no chance
to clean up or log anything. The kernel kills a process when the container's
cgroup exceeds its memory limit. On cgroup v2 hosts (which current
Kubernetes expects) the kubelet configures the container so that **all** its
processes are killed together; on legacy cgroup v1 hosts only the process the
kernel picks dies, and a container whose main process survives keeps running
– which is why the manifest `exec`s `dd` to make it the main process. The fix in real life is a higher limit or a smaller
memory footprint, never "more restarts".

```bash
kubectl delete pod oom-demo -n lab-pods
```

### 13. Graceful termination

```bash
kubectl apply -f modules/01-pods/14-graceful-termination.yaml
kubectl logs -f graceful -n lab-pods          # terminal 1: keep it open
```

In terminal 2:

```bash
time kubectl delete pod graceful -n lab-pods
```

Terminal 1 shows the whole shutdown sequence, and `time` reports about 8–10 seconds:

```
11:14:03 started, waiting for work
11:14:04 preStop hook: draining for 5s
11:14:09 got SIGTERM - finishing in-flight work
11:14:12 clean exit
```

preStop ran first (5s), *then* SIGTERM arrived, the handler finished its
work (3s) and exited 0 – well inside the 20s budget. Now the bad case:

```bash
time kubectl delete pod stubborn -n lab-pods
```

```
pod "stubborn" deleted from lab-pods namespace

real	0m11.018s
```

`sleep` is PID 1 and has no SIGTERM handler, so SIGTERM was ignored and the
kubelet waited the full `terminationGracePeriodSeconds: 10` before
SIGKILL. With the default of 30s, every rollout and every node drain of such
an app is slow, and its in-flight requests are cut off rather than finished.
Exercise 5 fixes it.

## Exercises

1. **Generate a run-to-completion pod.** With `kubectl run ... --dry-run=client -o yaml`,
   generate a pod `node-reporter` (`busybox:1.37`, `restartPolicy: Never`)
   that prints `I ran on <node name>` and exits. Add the node name with the
   Downward API and add resources. Check its logs and that its phase is `Succeeded`.
   *Hint:* everything after `--` becomes `args`; `fieldPath: spec.nodeName`.
   Solution: [`solutions/node-reporter.yaml`](solutions/node-reporter.yaml).

2. **Never Ready.** Apply [`exercises/broken-probe.yaml`](exercises/broken-probe.yaml).
   The pod is `Running` but `0/1` forever. Find out why using `kubectl describe`,
   fix the file and re-apply.
   *Hint:* read the `Unhealthy` event carefully and compare it with the container's `args`.
   Probe settings cannot be changed on a running pod: use `kubectl replace --force -f`.
   Solution: [`solutions/broken-probe.yaml`](solutions/broken-probe.yaml).

3. **Sidecar that blocks completion.** Apply [`exercises/classic-sidecar.yaml`](exercises/classic-sidecar.yaml)
   and watch it: the work finishes but the pod never completes (`1/2 NotReady`).
   Convert the `proxy` container into a native sidecar so the pod ends
   `Completed` on its own.
   *Hint:* one block moves, one line is added.
   Solution: [`solutions/native-sidecar.yaml`](solutions/native-sidecar.yaml).

4. **Resize a running pod.** Change the CPU request of
   `qos-burstable` to `20m` and its limit to `200m` **without restarting it**,
   then try the same trick to lower the CPU request of `qos-guaranteed`.
   *Hint:* `kubectl patch pod qos-burstable -n lab-pods --subresource resize --patch '{"spec":{"containers":[{"name":"app","resources":{"requests":{"cpu":"20m"},"limits":{"cpu":"200m"}}}]}}'`;
   compare `.spec.containers[0].resources` with `.status.containerStatuses[0].resources`
   and check `restartCount`.
   <details><summary>What you should see</summary>

   The burstable pod is resized in place, `restartCount` stays `0`, and the
   status shows the new values once the kubelet has applied them. A plain
   `kubectl patch` *without* `--subresource resize` is rejected (`pod updates may not change fields ...`).
   For the Guaranteed pod you get `Pod QOS Class may not change as a result of resizing`:
   lowering only the request would turn it into Burstable.
   </details>

5. **Make `stubborn` polite.** Without changing the image or
   `terminationGracePeriodSeconds`, make a copy of the `stubborn` pod
   (call it `not-stubborn`) that stops in about a second on `kubectl delete`.
   *Hint:* PID 1 needs a SIGTERM handler; a shell can provide one if the
   long-running command runs in the background.
   Solution: [`solutions/not-stubborn.yaml`](solutions/not-stubborn.yaml).

6. **Evicted, not OOMKilled.** Give a pod an `emptyDir` with `sizeLimit: 10Mi`
   and write 20 MiB into it. What happens, which component does it, and how
   does it look different from step 12?
   *Hint:* `dd if=/dev/zero of=/scratch/big bs=1M count=20`; watch
   `kubectl get events -n lab-pods`; look at `.status.phase`, `.status.reason`.
   Solution: [`solutions/emptydir-sizelimit.yaml`](solutions/emptydir-sizelimit.yaml).

## Cleanup

```bash
kubectl delete namespace lab-pods
```

## Further reading

* [Pods](https://kubernetes.io/docs/concepts/workloads/pods/) and [Pod lifecycle](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/)
* [Init containers](https://kubernetes.io/docs/concepts/workloads/pods/init-containers/) and [Sidecar containers](https://kubernetes.io/docs/concepts/workloads/pods/sidecar-containers/)
* [Define a command and arguments for a container](https://kubernetes.io/docs/tasks/inject-data-application/define-command-argument-container/)
* [Downward API](https://kubernetes.io/docs/concepts/workloads/pods/downward-api/)
* [Configure liveness, readiness and startup probes](https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/)
* [Resource management for pods and containers](https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/) and [Pod QoS classes](https://kubernetes.io/docs/concepts/workloads/pods/pod-qos/)
* [Resize CPU and memory resources assigned to containers](https://kubernetes.io/docs/tasks/configure-pod-container/resize-container-resources/)
* [Container lifecycle hooks](https://kubernetes.io/docs/concepts/containers/container-lifecycle-hooks/) and [Termination of pods](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/#pod-termination)
* [Node-pressure eviction](https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/)
