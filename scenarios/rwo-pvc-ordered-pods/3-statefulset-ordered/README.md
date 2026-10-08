# Pattern 3 — StatefulSet with `OrderedReady`

**Use it when** both pods run the same image and you want Kubernetes itself
to guarantee the order: `app-1` is **not created** until `app-0` is Running
and Ready. No init containers, no RBAC.

| | |
|---|---|
| Pods | StatefulSet `app`, 2 replicas: `app-0` (initialiser), `app-1` (follower) |
| Role | from the ordinal label `apps.kubernetes.io/pod-index` (GA in 1.32) |
| Ordering | `podManagementPolicy: OrderedReady` + readiness probe that only passes after initialisation; `minReadySeconds: 5` |
| Volume | ONE standalone PVC referenced in `volumes:` — **not** `volumeClaimTemplates` |
| Same node | required self pod-affinity on `app: ordered` |
| Services | `app-headless` (StatefulSet identity / DNS) and `app` (ClusterIP for clients) |
| Namespace | `lab-rwo-statefulset` |

## Files

| File | What it is |
|---|---|
| [`00-namespace.yaml`](00-namespace.yaml) | the namespace |
| [`01-pvc.yaml`](01-pvc.yaml) | the one shared RWO claim |
| [`02-services.yaml`](02-services.yaml) | headless + client Services |
| [`03-statefulset.yaml`](03-statefulset.yaml) | the StatefulSet |

## Lab

1. Apply everything at once — the controller does the ordering:

   ```bash
   kubectl apply -f scenarios/rwo-pvc-ordered-pods/3-statefulset-ordered/
   kubectl -n lab-rwo-statefulset get pods -o wide -w
   ```
   ```
   app-0   Pending   kube-training-worker2
   app-0   Running   kube-training-worker2     (0/1 - initialising)
   app-0   Running   kube-training-worker2     (1/1)
   app-1   Pending   <none>                    <- created only now
   app-1   Pending   kube-training-worker2     <- affinity: same node as app-0
   app-1   Running   kube-training-worker2
   ```

2. Compare timestamps:

   ```bash
   for p in app-0 app-1; do kubectl -n lab-rwo-statefulset get pod $p -o \
     jsonpath='{.metadata.name} created={.metadata.creationTimestamp} ready={.status.conditions[?(@.type=="Ready")].lastTransitionTime}{"\n"}'; done
   ```
   ```
   app-0 created=2026-10-08T10:14:11Z ready=2026-10-08T10:14:28Z
   app-1 created=2026-10-08T10:14:36Z ready=2026-10-08T10:14:38Z
   ```
   `app-1` was created 8 s after `app-0` became Ready (`minReadySeconds: 5`
   plus controller latency).

3. Ask the Service (load-balanced over both pods):

   ```bash
   kubectl -n lab-rwo-statefulset exec app-1 -- wget -qO- http://app/startup-order.txt
   ```
   ```
   2026-10-08T10:14:26Z app-0 (ordinal 0) ready on kube-training-worker2
   2026-10-08T10:14:37Z app-1 (ordinal 1) ready on kube-training-worker2
   ```

4. Restart only `app-0`. Its initialisation is idempotent, so it doesn't
   wipe the data `app-1` is serving:

   ```bash
   kubectl -n lab-rwo-statefulset delete pod app-0
   kubectl -n lab-rwo-statefulset logs app-0
   ```
   ```
   app-0: I am the initialiser
   app-0: data already initialised at 2026-10-08T10:15:41Z, skipping
   ```

5. Scale down — reverse order:

   ```bash
   kubectl -n lab-rwo-statefulset scale sts/app --replicas=0
   kubectl -n lab-rwo-statefulset get events --sort-by=.lastTimestamp | grep SuccessfulDelete
   ```
   `app-1` is deleted first; `app-0` only after `app-1` has fully terminated.

## What OrderedReady does and doesn't guarantee

| Operation | Order |
|---|---|
| Initial creation / scale up | 0, 1, 2… each waits for the previous one to be Running + Ready |
| Scale down / delete | highest ordinal first, each waits for the previous to terminate |
| Rolling update | highest ordinal first (1, then 0) |
| A single pod crashes/restarts later | **no ordering** — other pods keep running |

That last row is why the initialiser must be idempotent.

## Try it: what if the order isn't enforced?

Recreate the StatefulSet with `podManagementPolicy: Parallel` (the field is
immutable, so delete it first):

```bash
kubectl -n lab-rwo-statefulset delete sts app
sed 's/OrderedReady/Parallel/' scenarios/rwo-pvc-ordered-pods/3-statefulset-ordered/03-statefulset.yaml | kubectl apply -f -
kubectl -n lab-rwo-statefulset get pods      # app-1 RESTARTS > 0
kubectl -n lab-rwo-statefulset logs app-1 --previous
```
On an empty volume `app-1` starts together with `app-0`, finds no data and
crashes until `app-0` has initialised:
```
shared data missing - the initialiser has not run!
```
(Delete the PVC too if you want a truly empty volume for this test.)

## Cleanup

```bash
kubectl delete namespace lab-rwo-statefulset
```
