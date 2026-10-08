# Module 16 - Debugging

## Goal

Build a systematic habit for finding out *why* something in Kubernetes isn't
working, then practise it on ten realistically broken apps.

## What you'll learn

* A triage order that finds most problems in under a minute
* `kubectl get` / `describe` / `logs` (`-c`, `-f`, `--since`, `--tail`, `--previous`, `-l`) / `events` (`--for`, `--types`) / `exec` / `port-forward` / `top`
* Digging into `status` with `-o yaml`, `jsonpath`, `custom-columns` and `jq`
* `kubectl debug`: ephemeral containers (`--target`), pod copies (`--copy-to`, changing the command), node shells (`debug node/...`) and debugging profiles
* What each common failure state really means: `ImagePullBackOff`, `CrashLoopBackOff`, `CreateContainerConfigError`, `Pending`, `OOMKilled`, `Init:0/1`, Running-but-not-Ready, and "the Service doesn't work"

## Concepts

### The triage order

Work from the outside in. Each step either finds the problem or tells you
which step to do next.

```
kubectl get pods            what STATE is it in?  (the STATUS column is the best first clue)
   |
kubectl describe pod X      Events at the bottom + State/Last State/Reason/Exit Code per container
   |
kubectl logs X [-c C]       what did the app say?  (--previous if it restarted)
   |
kubectl get events          what else happened around it? (ReplicaSet, PVC, scheduler, ...)
   |
kubectl exec / debug        look from the inside: files, env, DNS, ports, processes
```

### What the STATUS column is telling you

| STATUS | Which stage failed | First thing to look at |
|---|---|---|
| `Pending` | **scheduling** (no node chosen) | `describe pod` -> `FailedScheduling` event: resources, taints, affinity, unbound PVC |
| `ContainerCreating` (for long) | **volume mount / network setup** on the node | `describe pod` events: `FailedMount`, `FailedAttachVolume`, CNI errors |
| `ErrImagePull` / `ImagePullBackOff` | **image pull** | `describe pod` events: wrong name/tag, private registry without `imagePullSecrets`, network |
| `CreateContainerConfigError` | **building the container config** | `describe pod`: missing ConfigMap/Secret or key, bad `runAsNonRoot` |
| `RunContainerError` / `StartError` | **starting the process** | `describe pod` -> Last State message: executable not found, bad mount |
| `CrashLoopBackOff` | **the app** starts and exits, repeatedly | `logs --previous`, Last State exit code |
| `OOMKilled` | **memory limit** exceeded (exit code 137) | `describe pod` Last State, compare limit with real usage |
| `Init:0/1`, `Init:CrashLoopBackOff` | an **init container** hasn't finished | `logs <pod> -c <init-container>` |
| `Running` but `READY 0/1` | **readiness probe** failing | `describe pod` -> `Unhealthy` events |
| `Running`, `1/1`, but "it doesn't work" | **networking / Service** | `get endpointslices`, selector vs labels, `targetPort`, test from inside |
| `Terminating` (for long) | **finalizers** or an unreachable node | `get -o yaml` -> `metadata.finalizers`, node status |

Note: STATUS is a kubectl summary, not the pod `phase`. A pod in
`CrashLoopBackOff` usually has `phase: Running`.

### Exit codes worth knowing

| Exit code | Meaning |
|---|---|
| 0 | process ended normally - in a Deployment that still counts as a crash (containers there must run forever) |
| 1, 2, 3 ... | the app's own error code - read its logs |
| 126 | command found but not executable (permissions) |
| 127 | command not found (from a shell: `sh -c "missing-binary"`) |
| 128 | container couldn't start (`StartError`) - e.g. the entrypoint itself doesn't exist |
| 137 | 128 + 9 (SIGKILL): OOM kill, or killed after `terminationGracePeriodSeconds` |
| 143 | 128 + 15 (SIGTERM): asked to stop and did |

### The `kubectl debug` family

| Command | What it creates | Use it when |
|---|---|---|
| `kubectl debug <pod> -it --image=busybox:1.37 --target=<container>` | an **ephemeral container** inside the running pod, sharing the target's process namespace | the image has no shell/tools (distroless, scratch); you must not restart the pod |
| `kubectl debug <pod> -it --copy-to=<new> --container=<c> -- sh` | a **copy** of the pod with a changed command (or `--set-image`, or an extra container) | the container crashes too fast to exec into; you want to experiment without touching the original |
| `kubectl debug node/<node> -it --image=busybox:1.37` | a pod on that node with the node's filesystem at `/host`, host PID/network namespaces | kubelet/containerd/disk/network problems on the node itself |

Ephemeral containers can't be removed or restarted; they disappear when the
pod is deleted. `--profile` chooses the security settings of the debug
container: `general` (default behaviour, adds `SYS_PTRACE`), `baseline`,
`restricted` (passes PSA restricted - see [module 15](../15-security/README.md)),
`netadmin` (`NET_ADMIN`/`NET_RAW`, for tcpdump), `sysadmin` (privileged).
Current kubectl defaults to `general`; older versions defaulted to a `legacy` profile and printed a deprecation warning when you didn't pass `--profile`.

## Files

| File | What it is |
|---|---|
| [`00-namespace.yaml`](00-namespace.yaml) | `lab-debugging` |
| [`01-web.yaml`](01-web.yaml) | Healthy Deployment `web` with two containers (`nginx` + `heartbeat`) and a Service - toolkit practice |
| [`02-flaky.yaml`](02-flaky.yaml) | Pod `flaky` that crashes every ~15 s - practise `--previous` and `lastState` |
| [`03-no-shell.yaml`](03-no-shell.yaml) | Pod `whoami` built FROM scratch (no shell) - practise ephemeral containers |
| [`broken/01-image-pull.yaml`](broken/01-image-pull.yaml) ... [`broken/10-stuck-init.yaml`](broken/10-stuck-init.yaml) | Ten broken apps, one bug each (see "Broken apps" below) |
| [`solutions/01-...yaml`](solutions/) ... `solutions/10-...yaml` | The fixed versions - same object names, so `kubectl apply` fixes in place |
| [`exercises/double-trouble.yaml`](exercises/double-trouble.yaml) | One app with two bugs (exercise 4) |
| [`solutions/ex-double-trouble.yaml`](solutions/ex-double-trouble.yaml) | Its solution |

## Lab

All commands are run from the repo root. Part A teaches the toolkit on
healthy (and one flaky) app, Part B is the broken apps.

### Part A - the toolkit

#### 1. Deploy the practice apps

```bash
kubectl apply -f modules/16-debugging/00-namespace.yaml
kubectl apply -f modules/16-debugging/01-web.yaml -f modules/16-debugging/02-flaky.yaml -f modules/16-debugging/03-no-shell.yaml
kubectl config set-context --current --namespace=lab-debugging   # saves typing -n; undo in Cleanup
```

> The rest of this module assumes the current namespace is `lab-debugging`.
> If you'd rather not change it, add `-n lab-debugging` to every command.

#### 2. `get`: the overview

```bash
kubectl get pods -o wide
kubectl get pods -l app=web --show-labels
kubectl get pods -w          # watch changes live; Ctrl-C to stop
```

```
NAME               READY   STATUS             RESTARTS      AGE     IP             NODE                    ...
flaky              0/1     CrashLoopBackOff   4 (15s ago)   3m23s   10.244.1.154   kube-training-worker2   ...
web-879484-572kw   2/2     Running            0             3m23s   10.244.1.153   kube-training-worker2   ...
web-879484-v77l8   2/2     Running            0             3m23s   10.244.2.117   kube-training-worker    ...
whoami             1/1     Running            0             3m23s   10.244.1.155   kube-training-worker2   ...

NAME               READY   STATUS    RESTARTS   AGE     LABELS
web-879484-572kw   2/2     Running   0          3m23s   app=web,pod-template-hash=879484
web-879484-v77l8   2/2     Running   0          3m23s   app=web,pod-template-hash=879484
```

`READY 2/2` = two containers, both ready. `RESTARTS 4 (15s ago)` = the
kubelet restarted a container four times, last one 15 s ago.

#### 3. `describe`: the story of one object

```bash
kubectl describe pod flaky
```

The two parts that matter most (trimmed):

```
    State:          Running
      Started:      Thu, 08 Oct 2026 11:08:29 +0000
    Last State:     Terminated
      Reason:       Error
      Exit Code:    3
      Started:      Thu, 08 Oct 2026 11:07:44 +0000
      Finished:     Thu, 08 Oct 2026 11:07:59 +0000
    Ready:          True
    Restart Count:  3
...
Events:
  Type     Reason     Age                   From               Message
  ----     ------     ----                  ----               -------
  Normal   Scheduled  95s                default-scheduler  Successfully assigned lab-debugging/flaky to kube-training-worker
  Warning  BackOff    31s (x2 over 58s)  kubelet            spec.containers{app}: Back-off restarting failed container app in pod flaky_lab-debugging(...)
  Normal   Pulled     3s (x4 over 92s)   kubelet            spec.containers{app}: Container image "busybox:1.37" already present on machine and can be accessed by the pod
  Normal   Created    3s (x4 over 92s)   kubelet            spec.containers{app}: Container created
  Normal   Started    1s (x4 over 91s)   kubelet            spec.containers{app}: Container started
```

`Last State` is the previous run of the container: it exited with code 3
after 15 seconds. The kubelet waits longer after each crash (10 s, 20 s, 40 s,
... capped at 5 min); that waiting is the `BackOff`. `describe` works on
everything: `kubectl describe deploy web`, `svc web`, `node <name>`, `pvc ...`.

#### 4. `logs`: what the app said

```bash
kubectl logs deploy/web                         # picks one pod, default container (nginx)
kubectl logs deploy/web -c heartbeat --tail=3   # a specific container, last 3 lines
kubectl logs -l app=web -c heartbeat --since=12s --prefix   # all pods matching a label
kubectl logs -f deploy/web -c heartbeat         # follow (Ctrl-C to stop)
kubectl logs web-879484-572kw --all-containers  # every container in one pod
```

```
Found 2 pods, using pod/web-879484-572kw
Defaulted container "nginx" out of: nginx, heartbeat
...
[pod/web-879484-572kw/heartbeat] 2026-10-08T10:29:57+00:00 heartbeat #38 from web-879484-572kw
[pod/web-879484-572kw/heartbeat] 2026-10-08T10:30:02+00:00 heartbeat #39 from web-879484-572kw
[pod/web-879484-v77l8/heartbeat] 2026-10-08T10:29:55+00:00 heartbeat #38 from web-879484-v77l8
[pod/web-879484-v77l8/heartbeat] 2026-10-08T10:30:00+00:00 heartbeat #39 from web-879484-v77l8
```

Now the crash. Wait until `flaky` shows `Running` again, then compare:

```bash
kubectl logs flaky              # the CURRENT container: just started
kubectl logs flaky --previous   # the one that crashed
```

```
2026-10-08T11:08:29+00:00 starting up
```
```
2026-10-08T11:07:44+00:00 starting up
2026-10-08T11:07:49+00:00 connected to queue
2026-10-08T11:07:59+00:00 FATAL: lost connection to queue (simulated)
```

`--previous` is the single most useful flag for crash loops. (While the pod
sits in `CrashLoopBackOff` waiting to restart, the "current" container *is*
the crashed one, so plain `logs` shows the crash too. The kubelet keeps only
one dead container per container, so you can't go back further than that -
ship logs to a central system for real history.)

#### 5. `events`: what happened around it

Events are separate API objects, kept for about an hour. `describe` shows
the events of one object; these show more:

```bash
kubectl events --for pod/flaky                  # one object, sorted by time
kubectl events --types=Warning                  # only warnings, whole namespace
kubectl get events --sort-by=.metadata.creationTimestamp   # the classic form
kubectl get events -A --field-selector type=Warning        # whole cluster
```

```
LAST SEEN           TYPE      REASON      OBJECT      MESSAGE
96s                 Normal    Scheduled   Pod/flaky   Successfully assigned lab-debugging/flaky to kube-training-worker
32s (x2 over 59s)   Warning   BackOff     Pod/flaky   Back-off restarting failed container app in pod flaky_lab-debugging(...)
4s (x4 over 93s)    Normal    Pulled      Pod/flaky   Container image "busybox:1.37" already present on machine and can be accessed by the pod
4s (x4 over 93s)    Normal    Created     Pod/flaky   Container created
2s (x4 over 92s)    Normal    Started     Pod/flaky   Container started
```

Events on *other* objects are often the key: a ReplicaSet that can't create
pods (quota, admission - see module 15's PSA demo), a PVC that can't be
provisioned, a node that is under pressure.

#### 6. `exec`: look from the inside

```bash
kubectl exec deploy/web -c nginx -- nginx -T | head -5          # dump effective nginx config
kubectl exec deploy/web -- wget -qO- localhost/ | head -4        # call the app from inside its pod
kubectl exec -it deploy/web -c nginx -- sh                       # interactive shell; exit to leave
kubectl exec whoami -- sh                                        # no shell in this image...
```

```
error: Internal error occurred: ... exec: "sh": executable file not found in $PATH
```

That last one is what step 8 solves.

#### 7. `port-forward` and `top`

```bash
kubectl port-forward svc/web 8080:80      # localhost:8080 -> a pod behind svc/web, port 80
# second terminal:
curl -sI localhost:8080 | head -2
```

```
Forwarding from 127.0.0.1:8080 -> 80
Handling connection for 8080
HTTP/1.1 200 OK
Server: nginx/1.27.5
```

`port-forward svc/...` picks **one** pod and tunnels to it through the API
server. It bypasses the Service's load balancing and kube-proxy, so "works
with port-forward, fails through the Service" points at the Service
(selector, ports) or NetworkPolicies.

```bash
kubectl top pods
kubectl top pods --containers
kubectl top nodes
```

`top` needs **metrics-server** (installed in [module 14](../14-autoscaling/README.md)).
Without it you get `error: Metrics API not available`. With it, you see
current CPU (millicores) and memory per pod/container - compare memory with
the limit when hunting OOM kills.

#### 8. Ephemeral debug containers: debugging a pod with no shell

```bash
kubectl debug -it whoami --image=busybox:1.37 --target=whoami --profile=general
```

`--target=whoami` puts the debug container in the **process namespace** of
the `whoami` container, so you can see and inspect its processes. Inside
the debug shell try:

```sh
ps                    # PID 1 is /whoami - the target's process
ls -l /proc/1/root/   # the TARGET's filesystem, seen through /proc
netstat -tlnp         # what it listens on
wget -qO- localhost:80 | head -3
exit
```

```
PID   USER     TIME  COMMAND
    1 root      0:00 /whoami
   20 root      0:00 sh
...
-rwxr-xr-x    1 root     root       5906584 Jan 21  2025 whoami
...
tcp        0      0 0.0.0.0:80              0.0.0.0:*               LISTEN      1/whoami
Hostname: whoami
IP: 127.0.0.1
IP: 10.244.1.155
```

The image's entire filesystem is one binary - and you still debugged it.
The ephemeral container is now a permanent part of the pod's spec:

```bash
kubectl get pod whoami -o jsonpath='{.spec.ephemeralContainers[*].name}{"\n"}'
kubectl describe pod whoami | grep -A3 'Ephemeral Containers'
```

For network problems use `nicolaka/netshoot:v0.13` instead of busybox
(curl, dig, ss, tcpdump, ...) - exercise 2.

#### 9. A shell on a node

```bash
kubectl debug node/kube-training-worker -it --image=busybox:1.37 --profile=sysadmin
```

This creates a pod named `node-debugger-kube-training-worker-xxxxx` **in the
current namespace**, on that node, with `hostPID`, `hostNetwork`, `hostIPC`,
the node's root filesystem mounted at `/host`, and (with `sysadmin`) a
privileged container. Inside:

```sh
ls /host                                  # the node's filesystem
chroot /host crictl ps | head -5          # containers on this node, as containerd sees them
chroot /host journalctl -u kubelet --no-pager -n 3   # kubelet logs (kind nodes run systemd)
ps | head -5                              # host PID namespace: systemd, containerd, kubelet...
exit
```

```
CONTAINER           IMAGE               CREATED          STATE     NAME        ATTEMPT   POD ID          POD                                        NAMESPACE
c41dffe705533       30ecbe1509090       1 second ago     Running   debugger    0         cbfafddf882c3   node-debugger-kube-training-worker-srs5v   lab-debugging
...
PID   USER     TIME  COMMAND
    1 root      0:07 {systemd} /sbin/init
  142 root      0:01 /lib/systemd/systemd-journald
  157 root      1:13 /usr/local/bin/containerd
  253 root      0:47 /usr/bin/kubelet --bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf ...
```

The debugger pod is **not** deleted when you exit. Clean it up:

```bash
kubectl get pods -o name | grep node-debugger                  # pod/node-debugger-kube-training-worker-srs5v
kubectl get pods -o name | grep node-debugger | xargs kubectl delete
```

(PSA note: this pod violates `baseline`, so in a namespace that enforces
`baseline`/`restricted` it is rejected - that's intended.)

#### 10. Copy a pod and change its command

`flaky` dies after 15 seconds - too fast to explore. Make a copy that just
sleeps, with the same image, env, volumes and node constraints:

```bash
kubectl debug flaky --copy-to=flaky-debug --container=app --profile=general -- sh -c 'sleep 3600'
kubectl get pods flaky flaky-debug
kubectl exec -it flaky-debug -- sh        # explore at leisure
```

```
NAME          READY   STATUS             RESTARTS      AGE
flaky         0/1     CrashLoopBackOff   5 (22s ago)   5m16s
flaky-debug   1/1     Running            0             5s
```

Variants:

```bash
# same pod, different image (e.g. a debug build):
kubectl debug flaky --copy-to=flaky-v2 --set-image=app=busybox:1.37 --profile=general
# same pod plus a debug container sharing its process namespace:
kubectl debug flaky -it --copy-to=flaky-shared --image=busybox:1.37 --share-processes -c sidecar -- sh
```

The copy has **no labels** (so a Service or ReplicaSet won't adopt it) and is
**not** cleaned up automatically: `kubectl delete pod flaky-debug flaky-v2 flaky-shared --ignore-not-found`.

#### 11. Digging into status with `-o yaml`, jsonpath and friends

Everything `describe` shows comes from the object's `status`. Querying it
directly is faster once you know where things are, and scriptable:

```bash
kubectl get pod flaky -o yaml | less                       # everything
kubectl get pod flaky -o jsonpath='{.status.containerStatuses[0].lastState.terminated.exitCode}{"\n"}'
kubectl get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\t"}{.spec.nodeName}{"\n"}{end}'
kubectl get pods -o custom-columns='NAME:.metadata.name,RESTARTS:.status.containerStatuses[*].restartCount,LAST:.status.containerStatuses[*].lastState.terminated.reason,NODE:.spec.nodeName'
kubectl get pod whoami -o yaml | yq '.status.conditions'   # if you have yq
```

```
3
flaky   Running kube-training-worker2
web-879484-572kw        Running kube-training-worker2
...
NAME               RESTARTS   LAST     NODE
flaky              5          Error    kube-training-worker2
web-879484-572kw   0,0        <none>   kube-training-worker2
...
```

And for anything jsonpath can't filter, pipe JSON to `jq`:

```bash
# every pod that has at least one container not ready
kubectl get pods -o json | jq -r '.items[] | select(any(.status.containerStatuses[]?; .ready == false)) | .metadata.name'
```

Useful paths to remember:

| Path | Tells you |
|---|---|
| `.status.phase` | Pending / Running / Succeeded / Failed / Unknown |
| `.status.conditions[]` | PodScheduled, Initialized, ContainersReady, Ready (with reasons/messages) |
| `.status.containerStatuses[].state` / `.lastState` | waiting/running/terminated, reason, exit code, message |
| `.status.containerStatuses[].restartCount` | restarts |
| `.status.initContainerStatuses[]` | same, for init containers |
| `.spec.nodeName` | where it was scheduled |

### Part B - ten broken apps

Rules: apply **one** broken app, find the cause **with kubectl only** (don't
read the YAML for the answer - you won't have the YAML in a real incident),
then open the answer. Every fix is in `solutions/` under the same object
names, so `kubectl apply -f modules/16-debugging/solutions/NN-...yaml` repairs it in place.

You can also apply all ten at once and triage them like a real on-call shift:

```bash
kubectl apply -f modules/16-debugging/broken/
kubectl get pods
```

```
NAME                               READY   STATUS                       RESTARTS      AGE
billing-api-747457db48-m4bg6       0/1     CreateContainerConfigError   0             14s
catalog-api-7cdcff4f5-msqwf        1/1     Running                      0             13s
catalog-api-7cdcff4f5-v5nvm        1/1     Running                      0             13s
catalog-client-56fd569546-xwm2t    1/1     Running                      0             13s
inventory-d5bf9fb59-ppfld          0/1     Init:0/1                     0             12s
inventory-redis-79d5499d54-gl9xj   1/1     Running                      0             12s
ml-trainer-5ff5fb4f87-vpjlj        0/1     Pending                      0             14s
orders-api-56d8bdf765-f8mh6        1/1     Running                      0             13s
orders-api-56d8bdf765-qtdm8        1/1     Running                      0             13s
orders-client-7d547b8b59-d4ggq     1/1     Running                      0             13s
report-worker-787fff7799-nzf8v     0/1     CrashLoopBackOff             1 (3s ago)    14s
shop-frontend-7c79b64cdd-r4zj9     0/1     ErrImagePull                 0             14s
status-page-8485c648db-55mpz       0/1     Running                      0             13s
status-page-8485c648db-v8frd       0/1     Running                      0             13s
thumbnailer-7fdc55d89d-nshd8       0/1     OOMKilled                    1 (10s ago)   13s
uploads-57547bf4cd-7hmss           0/1     Pending                      0             13s
...
```

Notice that two of the broken apps (`orders`, `catalog`) look perfectly
healthy here. Their problem only shows in the client logs.

---

#### Broken app 1 - `shop-frontend` ([`broken/01-image-pull.yaml`](broken/01-image-pull.yaml))

**Symptom:** `ErrImagePull`, then `ImagePullBackOff`.

**Investigate:** `kubectl describe pod -l app=shop-frontend` and read the Events.

<details>
<summary>Answer</summary>

```
Normal   Pulling    2s (x2 over 15s)  kubelet  spec.containers{nginx}: Pulling image "nginx:1.27-alpnie"
Warning  Failed     2s (x2 over 15s)  kubelet  spec.containers{nginx}: Failed to pull image "nginx:1.27-alpnie": failed to pull and unpack image "docker.io/library/nginx:1.27-alpnie": failed to resolve reference "docker.io/library/nginx:1.27-alpnie": docker.io/library/nginx:1.27-alpnie: not found
Warning  Failed     2s (x2 over 15s)  kubelet  spec.containers{nginx}: Error: ErrImagePull
Normal   BackOff    14s               kubelet  spec.containers{nginx}: Back-off pulling image "nginx:1.27-alpnie"
Warning  Failed     14s               kubelet  spec.containers{nginx}: Error: ImagePullBackOff
```

**Cause:** typo in the tag - `1.27-alpnie` instead of `1.27-alpine`. The
registry says `not found`.

**Fix:** [`solutions/01-image-pull.yaml`](solutions/01-image-pull.yaml).

Read the end of the message carefully, it tells different causes apart:
`not found` = wrong name/tag; `401 Unauthorized` / `403 Forbidden` /
`pull access denied` = private image without (correct) `imagePullSecrets`;
`dial tcp ... i/o timeout` / `connection refused` = the node can't reach the
registry (proxy, firewall, DNS). `ErrImagePull` is the failed attempt,
`ImagePullBackOff` the waiting period before the next attempt.
</details>

---

#### Broken app 2 - `report-worker` ([`broken/02-bad-command.yaml`](broken/02-bad-command.yaml))

**Symptom:** `RunContainerError`, then `CrashLoopBackOff`. `kubectl logs` is empty.

**Investigate:** logs are empty because the process never started - so
look at the container's Last State: `kubectl describe pod -l app=report-worker`.

<details>
<summary>Answer</summary>

```
    State:          Waiting
      Reason:       CrashLoopBackOff
    Last State:     Terminated
      Reason:       StartError
      Message:      failed to create containerd task: failed to create shim task: OCI runtime create failed: runc create failed: unable to start container process: error during container init: exec: "/bin/bash": stat /bin/bash: no such file or directory
      Exit Code:    128
```

**Cause:** `command: ["/bin/bash", "-c"]` - busybox only has `/bin/sh`. A
command copied from a Debian/Ubuntu-based example.

**Fix:** [`solutions/02-bad-command.yaml`](solutions/02-bad-command.yaml) (`/bin/sh`).

Lesson: `StartError` + exit code 128 = the runtime couldn't even exec the
entrypoint. If the *shell* had started and then failed to find a program
inside the script, you would instead see exit code 127 and a
`sh: xyz: not found` line in `kubectl logs`.
</details>

---

#### Broken app 3 - `billing-api` ([`broken/03-missing-config.yaml`](broken/03-missing-config.yaml))

**Symptom:** `CreateContainerConfigError`, no restarts, no logs.

**Investigate:** `kubectl describe pod -l app=billing-api` (Events), then
`kubectl get configmap billing-config -o yaml`.

<details>
<summary>Answer</summary>

```
Warning  Failed  4s (x3 over 16s)  kubelet  spec.containers{api}: Error: couldn't find key PAYMENT_GATEWAY in ConfigMap lab-debugging/billing-config
```

```bash
kubectl get configmap billing-config -o jsonpath='{.data}'; echo
# {"CURRENCY":"EUR","LOG_LEVEL":"info","PAYMENT_GATEWAY_URL":"http://payments.example.internal"}
```

**Cause:** the Deployment references key `PAYMENT_GATEWAY`; the ConfigMap has
`PAYMENT_GATEWAY_URL`. The kubelet can't assemble the environment, so the
container is never created (hence no logs, no restarts - it keeps retrying).

**Fix:** [`solutions/03-missing-config.yaml`](solutions/03-missing-config.yaml).
Alternatives: add the key to the ConfigMap, or mark the reference
`optional: true` if the app can live without it. A missing ConfigMap or Secret
(not just a key) gives the same status with `configmap "x" not found`.
</details>

---

#### Broken app 4 - `ml-trainer` ([`broken/04-huge-requests.yaml`](broken/04-huge-requests.yaml))

**Symptom:** `Pending` forever.

**Investigate:** `kubectl describe pod -l app=ml-trainer` -> the
`FailedScheduling` event. Compare with `kubectl describe nodes | grep -A 7 'Allocated resources'`.

<details>
<summary>Answer</summary>

```
Warning  FailedScheduling  1s (x10 over 17s)  default-scheduler  0/3 nodes are available: 1 node(s) had untolerated taint(s), 2 Insufficient cpu, 2 Insufficient memory. preemption: 0/3 nodes are available: 3 Preemption is not helpful for scheduling.
```

**Cause:** it requests 64 CPUs and 256Gi of memory. Requests must fit on a
single node's *allocatable* capacity minus what is already requested there.
The message counts the reason per node: the control plane is excluded by its
taint (`node-role.kubernetes.io/control-plane:NoSchedule`), the two workers
by insufficient CPU and memory.

**Fix:** [`solutions/04-huge-requests.yaml`](solutions/04-huge-requests.yaml) (realistic requests).
Other `FailedScheduling` reasons you'll meet: `didn't match Pod's node
affinity/selector`, `untolerated taint`, `didn't match pod anti-affinity
rules`, `node(s) didn't have free ports` - see [module 10](../10-scheduling/README.md).
</details>

---

#### Broken app 5 - `uploads` ([`broken/05-unbound-pvc.yaml`](broken/05-unbound-pvc.yaml))

**Symptom:** `Pending`, even though the cluster has plenty of free resources.

**Investigate:** `kubectl describe pod -l app=uploads`, then `kubectl get pvc`
and `kubectl describe pvc uploads-data`, then `kubectl get storageclass`.

<details>
<summary>Answer</summary>

```
Warning  FailedScheduling    17s                default-scheduler            0/3 nodes are available: pod has unbound immediate PersistentVolumeClaims. not found
```
```
NAME           STATUS    VOLUME   CAPACITY   ACCESS MODES   STORAGECLASS   ...
uploads-data   Pending                                      fast-ssd       ...

Warning  ProvisioningFailed  0s (x3 over 17s)   persistentvolume-controller  storageclass.storage.k8s.io "fast-ssd" not found
```
```
NAME                 PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE      ...
standard (default)   rancher.io/local-path   Delete          WaitForFirstConsumer   ...
```

**Cause:** the PVC asks for StorageClass `fast-ssd`, which doesn't exist
(maybe it does in production). Nothing provisions a volume, so the pod can't
be scheduled.

**Fix:** a PVC's spec is immutable, so applying the fix directly fails with
`spec is immutable after creation except resources.requests ...`. Recreate:

```bash
kubectl delete -f modules/16-debugging/broken/05-unbound-pvc.yaml
kubectl apply  -f modules/16-debugging/solutions/05-unbound-pvc.yaml
kubectl get pvc uploads-data     # Bound, STORAGECLASS standard
```

(Or create a `fast-ssd` StorageClass.) Note that with `standard`
(`WaitForFirstConsumer`) a *healthy* PVC also shows `Pending` until a pod
using it is scheduled - the difference is the `ProvisioningFailed` event.
See [module 06](../06-storage/README.md).
</details>

---

#### Broken app 6 - `orders-api` ([`broken/06-no-endpoints.yaml`](broken/06-no-endpoints.yaml))

**Symptom:** every pod is `Running` and `1/1`, but the client can't connect:

```bash
kubectl logs deploy/orders-client --tail=3
```
```
2026-10-08T10:28:04+00:00 curl: (7) Failed to connect to orders-api port 80 after 89 ms: Could not connect to server
```

**Investigate:** does the Service have endpoints?
`kubectl get endpointslices -l kubernetes.io/service-name=orders-api`, then
compare `kubectl get svc orders-api -o wide` (SELECTOR column) with
`kubectl get pods -l app=orders-api --show-labels`.

<details>
<summary>Answer</summary>

```
NAME               ADDRESSTYPE   PORTS     ENDPOINTS   AGE
orders-api-4tdlq   IPv4          <unset>   <unset>     34s

NAME         TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)   AGE   SELECTOR
orders-api   ClusterIP   10.96.246.201   <none>        80/TCP    34s   app=order-api,tier=backend

NAME                          READY   STATUS    ...   LABELS
orders-api-56d8bdf765-f8mh6   1/1     Running   ...   app=orders-api,pod-template-hash=56d8bdf765,tier=backend
```

**Cause:** the Service selects `app=order-api` (missing "s"); the pods are
`app=orders-api`. No pod matches, so there are no endpoints. kube-proxy
answers connections to a Service without endpoints with a reject, which is
why the client fails immediately instead of timing out.

**Fix:** [`solutions/06-no-endpoints.yaml`](solutions/06-no-endpoints.yaml). Quick test of a selector:
`kubectl get pods -l app=order-api,tier=backend` -> `No resources found`.
</details>

---

#### Broken app 7 - `catalog-api` ([`broken/07-wrong-targetport.yaml`](broken/07-wrong-targetport.yaml))

**Symptom:** like app 6 - client errors, all pods healthy - but this time the
Service **does** have endpoints.

```
2026-10-08T10:28:05+00:00 curl: (7) Failed to connect to catalog-api port 80 after 1 ms: Could not connect to server
```

**Investigate:** look at the *port* in the EndpointSlice, then test a pod IP
directly from inside the cluster:

```bash
kubectl get endpointslices -l kubernetes.io/service-name=catalog-api
kubectl exec deploy/catalog-client -- curl -sS --max-time 3 http://<one-pod-IP>:8080
kubectl exec deploy/catalog-client -- curl -sS --max-time 3 http://<one-pod-IP>:80
```

<details>
<summary>Answer</summary>

```
NAME                ADDRESSTYPE   PORTS   ENDPOINTS                   AGE
catalog-api-58dj2   IPv4          8080    10.244.2.122,10.244.1.168   35s
```

Port 8080 refuses, port 80 answers with `Hostname: catalog-api-...`.

**Cause:** `targetPort: 8080`, but `traefik/whoami` listens on 80. The
selector is right, so the pods are endpoints - on a port where nothing listens.

**Fix:** [`solutions/07-wrong-targetport.yaml`](solutions/07-wrong-targetport.yaml): it names the container port
(`name: http`) and uses `targetPort: http`, so Service and container can't
drift apart again. (To find out what a container really listens on when you
don't know: `kubectl debug` with netshoot and `ss -tlnp` - exercise 2.)
</details>

---

#### Broken app 8 - `status-page` ([`broken/08-readiness-port.yaml`](broken/08-readiness-port.yaml))

**Symptom:** `Running` but `READY 0/1`, the rollout never finishes
(`kubectl rollout status deploy/status-page` hangs).

**Investigate:** `kubectl describe pod -l app=status-page` (Events), and check
the endpoints' `ready` condition.

<details>
<summary>Answer</summary>

```
Warning  Unhealthy  5s (x20 over 91s)  kubelet  spec.containers{nginx}: Readiness probe failed: Get "http://10.244.3.10:8080/": dial tcp 10.244.3.10:8080: connect: connection refused
```
```bash
kubectl get endpointslices -l kubernetes.io/service-name=status-page \
  -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]} ready={.conditions.ready}{"\n"}{end}'
# 10.244.1.252 ready=false
# 10.244.3.10 ready=false
```

**Cause:** the readiness probe checks port 8080; nginx listens on 80. The
container is fine, but never Ready, so the Service doesn't send it traffic
(endpoints are listed with `ready=false`) and the Deployment never counts it
as available.

**Fix:** [`solutions/08-readiness-port.yaml`](solutions/08-readiness-port.yaml) (`port: http`).
Had this been a **liveness** probe, the kubelet would *restart* the healthy
container every few seconds instead - see exercise 4.
</details>

---

#### Broken app 9 - `thumbnailer` ([`broken/09-oomkilled.yaml`](broken/09-oomkilled.yaml))

**Symptom:** STATUS flips between `OOMKilled` and `CrashLoopBackOff`;
RESTARTS keeps growing. Logs only show `loading 150 MB model into memory...`.

**Investigate:** `kubectl describe pod -l app=thumbnailer` (State / Last
State), or straight from status:

```bash
kubectl get pods -l app=thumbnailer -o jsonpath='{range .items[*]}{.metadata.name}{" last="}{.status.containerStatuses[0].lastState.terminated.reason}{" exit="}{.status.containerStatuses[0].lastState.terminated.exitCode}{"\n"}{end}'
```

<details>
<summary>Answer</summary>

```
    Last State:     Terminated
      Reason:       OOMKilled
      Exit Code:    137
...
    Limits:
      cpu:     200m
      memory:  64Mi
```
```
thumbnailer-7fdc55d89d-nshd8 last=OOMKilled exit=137
```

**Cause:** the process needs ~150 MB, the memory limit is 64Mi. Exceeding a
memory limit gets the container killed by the kernel's OOM killer (SIGKILL ->
exit code 137). The app gets no chance to log anything.

**Fix:** [`solutions/09-oomkilled.yaml`](solutions/09-oomkilled.yaml): limit 256Mi and a request close to
real usage (192Mi). In real life, first check whether the usage is legitimate
or a leak (`kubectl top pod --containers` over time, with metrics-server).
CPU limits never cause kills - only throttling.
</details>

---

#### Broken app 10 - `inventory` ([`broken/10-stuck-init.yaml`](broken/10-stuck-init.yaml))

**Symptom:** `Init:0/1` for minutes. `inventory-redis` is up and running.

**Investigate:** the app container hasn't started, so `kubectl logs deploy/inventory`
gives `is waiting to start: PodInitializing`. Read the **init container's** logs:

```bash
kubectl logs deploy/inventory -c wait-for-cache --tail=3
kubectl get svc
```

<details>
<summary>Answer</summary>

```
2026-10-08T10:28:27+00:00 waiting for inventory-cache:6379 ...
nc: bad address 'inventory-cache'
2026-10-08T10:28:31+00:00 waiting for inventory-cache:6379 ...
```
```
NAME              TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)    AGE
inventory-redis   ClusterIP   10.96.235.224   <none>        6379/TCP   51s
...
```

**Cause:** the init container waits for `inventory-cache`, but the Service is
called `inventory-redis` (as the app's own `REDIS_HOST` says). `bad address` =
DNS name doesn't resolve. Init containers run to completion one by one before
any app container starts, so the pod is stuck.

**Fix:** [`solutions/10-stuck-init.yaml`](solutions/10-stuck-init.yaml). Good "wait-for" init containers log what
they're waiting for (this one does - that's why it was quick to find) and,
ideally, give up after a deadline so the pod fails visibly. For ordering pods
that share a ReadWriteOnce volume, see
[the RWO scenario](../../scenarios/rwo-pvc-ordered-pods/README.md).
</details>

---

Once you've fixed them all:

```bash
kubectl get pods        # everything Running and READY
kubectl logs deploy/orders-client --tail=1    # orders-api: 3 open orders
kubectl logs deploy/catalog-client --tail=1   # Hostname: catalog-api-...
kubectl logs deploy/inventory --tail=1        # items in stock: N
```

## Exercises

1. **Restart report.** Write one command that prints every pod in
   `lab-debugging` with its total restart count and last termination reason,
   sorted by restarts.
   *Hint:* `custom-columns` plus `--sort-by='.status.containerStatuses[0].restartCount'`.

2. **What is it listening on?** Using an ephemeral `nicolaka/netshoot:v0.13`
   container, find out which port a `catalog-api` pod listens on *without*
   looking at any YAML, then watch the client's requests arrive with `tcpdump`.
   *Hint:* `kubectl debug <pod> -it --image=nicolaka/netshoot:v0.13 --target=api --profile=netadmin`,
   then `ss -tlnp` and `tcpdump -i any -nn port 80`. Without `--profile=netadmin`
   tcpdump fails: it needs `NET_RAW`/`NET_ADMIN`.

3. **Find the log file on the node.** Pick a `web` pod, find its node
   (`-o wide`), open a node shell and locate the container's log file under
   `/host/var/log/pods/`. What does `kubectl logs` actually read?
   *Hint:* the directory name is `<namespace>_<pod>_<uid>`; the kubelet serves
   these files - which is also why logs disappear when the pod is deleted.

4. **Double trouble.** Apply [`exercises/double-trouble.yaml`](exercises/double-trouble.yaml).
   It has two bugs; fixing the first reveals the second. Goal: `1/1 Running`
   with RESTARTS staying at 0 for two minutes.
   *Hint:* first look at the Events, then at the RESTARTS column and Events again.
   Solution: [`solutions/ex-double-trouble.yaml`](solutions/ex-double-trouble.yaml)
   (bug 1: `secret "checkout-secrets" not found`; bug 2: `Liveness probe failed: HTTP probe failed with statuscode: 404`).

5. **Break it yourself.** Write your own broken app for a friend, using a
   failure mode not covered here, e.g. a liveness probe whose
   `initialDelaySeconds` is shorter than the app's startup time (fix: a
   `startupProbe`), a Job that hits `backoffLimit`, a NetworkPolicy that blocks
   DNS (module 13), or a pod stuck `Terminating` because of a finalizer.

## Cleanup

```bash
kubectl delete namespace lab-debugging
kubectl config set-context --current --namespace=default
```

If you ran `kubectl debug node/...` from another namespace, delete the
leftover `node-debugger-*` pod there too.

## Further reading

* [Debug Pods](https://kubernetes.io/docs/tasks/debug/debug-application/debug-pods/)
* [Debug Running Pods (ephemeral containers, `kubectl debug`)](https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/)
* [Debug Services](https://kubernetes.io/docs/tasks/debug/debug-application/debug-service/)
* [Determine the Reason for Pod Failure](https://kubernetes.io/docs/tasks/debug/debug-application/determine-reason-pod-failure/)
* [Debugging Kubernetes Nodes With kubectl](https://kubernetes.io/docs/tasks/debug/debug-cluster/kubectl-node-debug/)
* [Ephemeral Containers](https://kubernetes.io/docs/concepts/workloads/pods/ephemeral-containers/)
* [JSONPath Support](https://kubernetes.io/docs/reference/kubectl/jsonpath/)
* [Pod Lifecycle (phases, conditions, container states)](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/)
* Related: [`docs/troubleshooting.md`](../../docs/troubleshooting.md), [module 01 - probes](../01-pods/README.md), [module 04 - Services](../04-services/README.md)
