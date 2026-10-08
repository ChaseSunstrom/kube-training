# Pattern 2 — Concurrent sharing with ordered start-up

**Use it when** pod A is long-running (it keeps producing data) and pod B
must only start once A has initialised — and then both run side by side on
the same RWO volume. Examples: a content generator + web server, a log/metrics
writer + a reader, an app + a file-processing worker.

| | |
|---|---|
| Pod A | Deployment `writer` (busybox) — initialises `www/`, then appends a heartbeat every 5 s |
| Pod B | Deployment `web` (nginx) — serves `www/` read-only |
| "A is ready" signal | A's readiness probe → Service `writer` has endpoints only when A is Ready |
| Ordering | B's init container polls `http://writer:8080/ready` until it answers |
| Same node | `rwo-group: shared-data` label + required self-matching pod affinity on both |
| Namespace | `lab-rwo-concurrent` |

## Files

| File | What it is |
|---|---|
| [`00-namespace.yaml`](00-namespace.yaml) | the namespace |
| [`01-pvc.yaml`](01-pvc.yaml) | shared RWO claim |
| [`02-deployment-writer.yaml`](02-deployment-writer.yaml) | **pod A** with startup/readiness/liveness probes |
| [`03-service-writer.yaml`](03-service-writer.yaml) | internal Service used as the readiness signal |
| [`04-deployment-web.yaml`](04-deployment-web.yaml) | **pod B** with the waiting init container |
| [`05-service-web.yaml`](05-service-web.yaml) | the Service clients use |

## Lab

1. **Pod B first** (plus both Services):

   ```bash
   cd scenarios/rwo-pvc-ordered-pods/2-concurrent-ordered-start
   kubectl apply -f 00-namespace.yaml -f 01-pvc.yaml -f 03-service-writer.yaml \
                 -f 04-deployment-web.yaml -f 05-service-web.yaml
   kubectl -n lab-rwo-concurrent logs deploy/web -c wait-for-writer-ready -f
   ```
   ```
   waiting for pod A (Service writer) to become Ready...
   wget: can't connect to remote host (10.96.85.79): Connection refused
   2026-10-08T10:11:24Z writer not ready yet
   ```
   "Connection refused" comes from kube-proxy: a Service with no Ready
   endpoints rejects connections.

2. **Start pod A** in a second terminal and watch:

   ```bash
   kubectl apply -f 02-deployment-writer.yaml
   kubectl -n lab-rwo-concurrent get pods -o wide -w
   ```
   The writer spends ~10 s initialising (`0/1 Running`), turns `1/1`, and a
   couple of seconds later the web pod's init container exits:
   ```
   2026-10-08T10:11:36Z writer not ready yet
   2026-10-08T10:11:38Z writer is Ready - starting web
   ```

3. **Both pods, one node, one RWO volume, at the same time:**

   ```bash
   kubectl -n lab-rwo-concurrent get pods -o wide
   ```
   ```
   NAME                     READY   STATUS    NODE
   web-768b7bbf4f-4nxr9     1/1     Running   kube-training-worker2
   writer-d5bfc5ff4-94ntj   1/1     Running   kube-training-worker2
   ```

4. **See live data written by A and served by B:**

   ```bash
   kubectl -n lab-rwo-concurrent port-forward svc/web 8080:80 &
   curl -s localhost:8080
   curl -s localhost:8080/heartbeat.txt | tail -3
   ```
   ```
   2026-10-08T10:11:36Z heartbeat from writer-d5bfc5ff4-94ntj
   2026-10-08T10:11:41Z heartbeat from writer-d5bfc5ff4-94ntj
   2026-10-08T10:11:46Z heartbeat from writer-d5bfc5ff4-94ntj
   ```

5. **Scale B and restart A** — everything stays on one node:

   ```bash
   kubectl -n lab-rwo-concurrent scale deploy/web --replicas=2
   kubectl -n lab-rwo-concurrent rollout restart deploy/writer
   kubectl -n lab-rwo-concurrent get pods -o wide
   ```

## Why each piece is there

* **Readiness instead of a marker file** — a marker on the volume outlives the
  pod that wrote it; after a redeploy, B could start on the *old* marker
  before the *new* A has initialised. Readiness always belongs to the current
  pod.
* **startupProbe** — gives A up to 2 minutes to initialise before the
  liveness probe could kill it.
* **Polling a Service** — no RBAC, no kubectl image, and the same trick works
  for any dependency with a Service (`nc -z postgres 5432`, etc.).
* **`readOnly: true` + `subPath: www` in B** — B can't corrupt A's data and
  only sees the published folder.
* **`strategy: Recreate`** on both — never a surge pod competing for the volume.

## Limits of this pattern

* The order is enforced **at B's start-up only**. If A restarts later, B
  keeps running (that's usually what you want — it keeps serving the last
  data). If B must stop when A is unhealthy, give B a liveness/readiness check
  that depends on A.
* Two writers on one filesystem need coordination. Here only A writes; if
  both must write, use separate directories or real locking — or
  `ReadWriteOncePod` with a hand-off ([pattern 4](../4-rwop-strict-handoff/README.md)).

## Cleanup

```bash
kubectl delete namespace lab-rwo-concurrent
```
