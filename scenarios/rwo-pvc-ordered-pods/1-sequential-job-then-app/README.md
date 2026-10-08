# Pattern 1 — Sequential hand-off: Job (pod A) → Deployment + Service (pod B)

**Use it when** pod A is a one-off step that must *finish successfully*
before pod B may touch the data: database migrations, seeding, restoring a
backup, downloading a model, building static content.

| | |
|---|---|
| Pod A | Job `seed` — writes `www/index.html` and a `.seed-complete` marker, then exits |
| Pod B | Deployment `web` (nginx) — serves `www/` read-only |
| Ordering | init containers in B: `kubectl wait --for=create job/seed`, then `--for=condition=complete`, then verify the marker |
| Same node | label `rwo-group: shared-data` + required self-matching pod affinity on both pod templates |
| Volume | PVC `shared-data`, `ReadWriteOnce`, 1Gi, default StorageClass |
| Namespace | `lab-rwo-sequential` |

## Files

| File | What it is |
|---|---|
| [`00-namespace.yaml`](00-namespace.yaml) | the namespace |
| [`01-pvc.yaml`](01-pvc.yaml) | the shared RWO claim |
| [`02-rbac.yaml`](02-rbac.yaml) | ServiceAccount `web` + Role allowing `get/list/watch` on Jobs |
| [`03-job-seed.yaml`](03-job-seed.yaml) | **pod A** |
| [`04-deployment-web.yaml`](04-deployment-web.yaml) | **pod B**, `strategy: Recreate`, 3 init containers |
| [`05-service.yaml`](05-service.yaml) | ClusterIP Service `web` → pod B |

## Lab

1. **Apply pod B first** — on purpose, to show the order doesn't depend on you:

   ```bash
   cd scenarios/rwo-pvc-ordered-pods/1-sequential-job-then-app
   kubectl apply -f 00-namespace.yaml -f 01-pvc.yaml -f 02-rbac.yaml \
                 -f 04-deployment-web.yaml -f 05-service.yaml
   kubectl -n lab-rwo-sequential get pods -o wide
   ```
   ```
   NAME                   READY   STATUS     RESTARTS   AGE   NODE
   web-646bd89d67-n8k2w   0/1     Init:0/3   0          6s    kube-training-worker2
   ```
   Pod B was scheduled (and the PV was provisioned on its node), but it is
   stuck in its first init container: the Job doesn't exist yet. The Service
   has no endpoints — `kubectl -n lab-rwo-sequential get endpointslices`.

2. **Now create pod A** and watch both pods (`Ctrl-C` to stop watching):

   ```bash
   kubectl apply -f 03-job-seed.yaml
   kubectl -n lab-rwo-sequential get pods -o wide -w
   ```
   ```
   NAME                   READY   STATUS     NODE
   seed-trbxc             1/1     Running    kube-training-worker2   <- same node as web: affinity
   web-646bd89d67-n8k2w   0/1     Init:1/3   kube-training-worker2   <- Job exists, now waiting for Complete
   seed-trbxc             0/1     Completed  kube-training-worker2
   web-646bd89d67-n8k2w   0/1     PodInitializing
   web-646bd89d67-n8k2w   1/1     Running
   ```

3. **Read the story from the logs:**

   ```bash
   kubectl -n lab-rwo-sequential logs job/seed
   kubectl -n lab-rwo-sequential logs deploy/web -c wait-for-seed-job-complete
   kubectl -n lab-rwo-sequential logs deploy/web -c verify-seed-data
   ```
   ```
   2026-10-08T10:09:41Z seed: starting on node kube-training-worker2
   2026-10-08T10:09:41Z seed: doing slow work for 15s...
   2026-10-08T10:09:56Z seed: done
   job.batch/seed condition met
   seed data present, completed at 2026-10-08T10:09:56Z
   ```

4. **Prove the order with timestamps** — the Job's completion time must be
   before nginx's start time:

   ```bash
   kubectl -n lab-rwo-sequential get job seed -o jsonpath='{.status.completionTime}{"\n"}'
   kubectl -n lab-rwo-sequential get pod -l app=web \
     -o jsonpath='{.items[0].status.containerStatuses[0].state.running.startedAt}{"\n"}'
   ```
   ```
   2026-10-08T10:09:58Z
   2026-10-08T10:10:01Z
   ```

5. **Hit the Service:**

   ```bash
   kubectl -n lab-rwo-sequential run curl --rm -it --restart=Never \
     --image=curlimages/curl:8.11.1 -- curl -s http://web
   ```
   ```html
   <h1>Hello from the shared RWO volume</h1>
   <p>Seeded by pod seed-trbxc on node kube-training-worker2 at 2026-10-08T10:09:41Z.</p>
   ```

6. **Restart pod B.** The Job is still there and Complete, so the init
   containers pass immediately:

   ```bash
   kubectl -n lab-rwo-sequential rollout restart deploy/web
   kubectl -n lab-rwo-sequential rollout status deploy/web
   ```

## Why each piece is there

* **`kubectl wait --for=create` before `--for=condition=complete`** —
  `wait --for=condition` fails immediately with `NotFound` if the Job doesn't
  exist yet. `--for=create` (kubectl ≥ 1.31) waits for it to appear first.
* **`rancher/kubectl` image** — a small, distroless image whose entrypoint is
  `kubectl`, so the init containers only pass `args`. Any image with kubectl
  ≥ 1.31 works.
* **RBAC** — in-cluster kubectl authenticates as the pod's ServiceAccount.
  Without the Role the init container log shows
  `Error from server (Forbidden): ... User "system:serviceaccount:lab-rwo-sequential:web" cannot ...`.
* **Marker file check** — defence in depth: the Job's status says it
  succeeded, the marker proves the data actually landed on *this* volume.
* **`restartPolicy: OnFailure` on the Job** — retries stay in the same pod,
  on the same node, with the volume already mounted.
* **No `ttlSecondsAfterFinished`** — see the table in the
  [scenario README](../README.md#things-that-go-wrong-and-how-these-patterns-avoid-them).
* **`strategy: Recreate`** — never two web pods during an update.
* **Co-location affinity** — makes "B first" safe: A is forced onto the node
  where B already holds the volume. Without it, on cloud disks, A could land
  elsewhere, hit `Multi-Attach error`, and B would wait forever.

## Variations

* **Re-run the seed** (e.g. new content): `kubectl -n lab-rwo-sequential delete job seed`,
  `kubectl apply -f 03-job-seed.yaml`, then `kubectl rollout restart deploy/web`.
  Running web pods keep serving the old files until the seed overwrites them.
* **More replicas of web** work: they all join the same node.
* **No kubectl in the cluster?** Replace the two kubectl init containers with
  a busybox loop `until [ -f /data/.seed-complete ]; do sleep 2; done` — no
  RBAC needed, but the marker can be stale after redeploys.

## Cleanup

```bash
kubectl delete namespace lab-rwo-sequential
```
