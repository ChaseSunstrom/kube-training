# Pattern 4 — Strict `ReadWriteOncePod` hand-off

**Use it when** two pods must *never* have the volume mounted at the same
time — e.g. SQLite or another embedded database, or any app that would
corrupt files with two writers. `ReadWriteOncePod` (RWOP) makes Kubernetes
enforce "one pod at a time" for you; this pattern adds the order.

| | |
|---|---|
| Volume | PVC `shared-data`, **`ReadWriteOncePod`** |
| Pod A | Job `seed`: init container writes the data, main container runs `kubectl scale deployment/web --replicas=1` |
| Pod B | Deployment `web` (nginx), **created with `replicas: 0`**, `strategy: Recreate` |
| Ordering | by construction: B doesn't exist until A has written the data; B can't be scheduled until A's pod has finished |
| RBAC | ServiceAccount `seed` may `get` the Deployment and `get/update/patch` its `scale` subresource — only for `web` |
| Namespace | `lab-rwo-rwop` |

No pod affinity here: the pods never overlap, so they don't need to share a node.

## Files

| File | What it is |
|---|---|
| [`00-namespace.yaml`](00-namespace.yaml) | the namespace |
| [`01-pvc.yaml`](01-pvc.yaml) | the RWOP claim |
| [`02-rbac.yaml`](02-rbac.yaml) | least-privilege "may scale deployment/web" |
| [`03-deployment-web.yaml`](03-deployment-web.yaml) | **pod B** at 0 replicas |
| [`04-service.yaml`](04-service.yaml) | Service `web` |
| [`05-job-seed.yaml`](05-job-seed.yaml) | **pod A** + the hand-off |

## Lab

1. Apply everything:

   ```bash
   kubectl apply -f scenarios/rwo-pvc-ordered-pods/4-rwop-strict-handoff/
   kubectl -n lab-rwo-rwop get pods -o wide -w
   ```
   ```
   NAME                   READY   STATUS     NODE
   seed-gplxf             0/1     Init:0/1   kube-training-worker2    <- writing data
   seed-gplxf             1/1     Running    kube-training-worker2    <- hand-off: kubectl scale
   web-789f6c6b65-dsdm5   0/1     Pending    <none>                   <- created, but the claim is taken
   seed-gplxf             0/1     Completed  kube-training-worker2    <- claim released
   web-789f6c6b65-dsdm5   0/1     ContainerCreating kube-training-worker2
   web-789f6c6b65-dsdm5   1/1     Running    kube-training-worker2
   ```

2. Read why pod B was Pending:

   ```bash
   kubectl -n lab-rwo-rwop get events --field-selector reason=FailedScheduling
   ```
   ```
   0/3 nodes are available: 1 node(s) had untolerated taint(s), 2 node(s) unavailable due to
   PersistentVolumeClaim with ReadWriteOncePod access mode already in-use by another pod. ...
   ```
   That is the RWOP guarantee in action: as long as *any* pod in the cluster
   uses the claim, no other pod can be scheduled with it.

3. Check the hand-off and the result:

   ```bash
   kubectl -n lab-rwo-rwop logs job/seed -c seed
   kubectl -n lab-rwo-rwop logs job/seed -c hand-off     # deployment.apps/web scaled
   kubectl -n lab-rwo-rwop exec deploy/web -- wget -qO- http://web
   ```

4. Try to break the exclusivity — start a second pod on the claim while web runs:

   ```bash
   kubectl -n lab-rwo-rwop run intruder --image=busybox:1.37 --restart=Never \
     --overrides='{"spec":{"volumes":[{"name":"d","persistentVolumeClaim":{"claimName":"shared-data"}}],"containers":[{"name":"intruder","image":"busybox:1.37","command":["sleep","3600"],"volumeMounts":[{"name":"d","mountPath":"/data"}]}]}}'
   kubectl -n lab-rwo-rwop get pod intruder     # Pending, same reason
   kubectl -n lab-rwo-rwop delete pod intruder
   ```

## Why not pattern 1 with an RWOP volume?

Because it can deadlock. If pod B (with init containers waiting for the Job)
is scheduled first, B owns the claim while it waits; pod A can never be
scheduled, so the Job never completes, so B waits forever. Reproduce it with
[`../broken/02-rwop-init-wait-deadlock.yaml`](../broken/02-rwop-init-wait-deadlock.yaml).
The rule: **with RWOP, pod B must not exist until pod A is done** — which is
exactly what scaling from 0 achieves.

## Caveats

* **Re-applying `03-deployment-web.yaml` resets `replicas` to 0** and stops
  the app. To redeploy: `kubectl -n lab-rwo-rwop delete job seed` and apply
  the Job again — it scales web back up when it's finished. With GitOps
  (Argo CD/Flux), ignore `spec.replicas` on this Deployment, or order the
  steps with sync waves/hooks instead.
* **Every update of web is downtime** (Recreate + RWOP: the old pod must be
  gone before the new one can mount the volume). That's the price of strict
  single-writer storage.
* **RWOP support** requires a CSI driver that implements it (Kubernetes 1.29+
  GA). kind's local-path provisioner accepts it and the scheduler enforces it.

## Cleanup

```bash
kubectl delete namespace lab-rwo-rwop
```
