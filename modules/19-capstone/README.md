# Module 19 - Capstone

## Goal

Build and run a small, production-shaped three-tier app on Kubernetes from
an empty namespace, using everything from modules 01-18, and prove it meets
a list of acceptance criteria with an automated check.

## What you'll learn

* Turning requirements into a set of Kubernetes objects - and in which order they depend on each other
* Running a stateful database properly: StatefulSet, PVC, Secret, probes, seeding, backups
* Making stateless tiers resilient: replicas, probes, PDBs, HPA, topology spread, rolling updates
* Locking it down: Pod Security `restricted`, non-root, read-only filesystems, least-privilege NetworkPolicies
* Packaging the whole thing with Kustomize, and verifying it with a script instead of by eye

## Concepts

### The project brief

You are the platform engineer for a tiny web shop. The developers hand you
four files - the application code - and ask you to run it on Kubernetes:

| File (in [`solutions/base/files/`](solutions/base/files/)) | What it is |
|---|---|
| [`api.sh`](solutions/base/files/api.sh) | The backend "API": a shell script served by `nc -lk -p 8080 -e /app/api.sh` inside the `postgres:16-alpine` image (which has `psql` and BusyBox `nc`). Endpoints: `/healthz`, `/api/health`, `/api/items`. Reads its DB connection from the libpq env vars `PGHOST`, `PGUSER`, `PGPASSWORD`, `PGDATABASE`. |
| [`default.conf`](solutions/base/files/default.conf) | nginx server config for the frontend: serves the page on `/`, proxies `/api/` to `http://backend:8080`, `/healthz` for probes, listens on 8080. |
| [`index.html`](solutions/base/files/index.html) | The page; it calls `/api/items` and lists the products. |
| [`seed.sql`](solutions/base/files/seed.sql) | Creates the `items` table and three demo rows (idempotent). |

Using these files is **not** looking at the solution - they're your input.
(The backend is a shell script only because this course builds no custom
images; in real life it would be your team's application image.)

```
              capstone.localtest.me
                       |
                   [Ingress]
                       |
                 svc/frontend :80
                       |
   +-------------------+-------------------+
   | frontend (nginx:1.27-alpine) x2, :8080 |   static page + proxy /api/
   +-------------------+-------------------+
                       |  /api/*
                 svc/backend :8080
                       |
   +-------------------+-------------------+
   | backend (postgres:16-alpine + api.sh)  |   x2..5 (HPA), PDB
   +-------------------+-------------------+
                       |  psql
                   svc/db :5432 (headless)
                       |
   +-------------------+-------------------+          +---------------------+
   | db-0  StatefulSet postgres:16-alpine   |<---------| Job db-seed (once)  |
   |       PVC data-db-0 (1Gi)              |<---------| CronJob db-backup   |--> PVC db-backups
   +----------------------------------------+          +---------------------+
```

### The contract (names `verify.sh` relies on)

Build it any way you like, but use these names so the checker can find things:

| What | Name / value |
|---|---|
| Namespace | `lab-capstone` |
| Database | StatefulSet `db` (pod `db-0`), image `postgres:16-alpine`, headless Service `db` on 5432, table `items(id, name, price)` |
| Seeding | Job `db-seed` |
| Backups | CronJob `db-backup` |
| Backend | Deployment `backend`, Service `backend` on port 8080, pod label `app: backend` |
| Frontend | Deployment `frontend` (`nginx:1.27-alpine`), Service `frontend` on port 80, pod label `app: frontend` |
| Ingress | host `capstone.localtest.me` -> Service `frontend` |
| Labels | `app: <name>` on every object and pod (module conventions) |

### Acceptance criteria

`./modules/19-capstone/verify.sh` checks every item below (section numbers
match its output).

1. **Namespace & Pod Security** - `lab-capstone` exists and *enforces* the `restricted` Pod Security Standard.
2. **Database**
   - [ ] StatefulSet `db` with 1 ready replica running PostgreSQL 16
   - [ ] data on a PVC from `volumeClaimTemplates`, and it is `Bound`
   - [ ] credentials come from a Secret (no password literals in the spec)
   - [ ] Service `db` on port 5432
3. **Seed data**
   - [ ] Job `db-seed` succeeded and table `items` has at least 3 rows
4. **Backend**
   - [ ] at least 2 available replicas, each container has readiness *and* liveness probes
   - [ ] Service `backend`, a PodDisruptionBudget selecting `app: backend`
   - [ ] an HPA targeting `backend` with `minReplicas >= 2`
5. **Frontend**
   - [ ] at least 2 available replicas of `nginx:1.27-alpine`, nginx config mounted from a ConfigMap
   - [ ] Service `frontend`
6. **Every container** (Deployments, StatefulSets, Jobs, CronJobs)
   - [ ] sets `requests.cpu`, `requests.memory` and `limits.memory`
   - [ ] `readOnlyRootFilesystem: true` and `allowPrivilegeEscalation: false`
7. **It works**
   - [ ] `GET /` through the frontend returns 200
   - [ ] `GET /api/items` through the frontend returns the rows from the database
8. **NetworkPolicies**
   - [ ] a default-deny policy for ingress *and* egress
   - [ ] DNS works; frontend -> backend:8080 and backend -> db:5432 are allowed
   - [ ] frontend -> db and backend -> frontend are blocked
9. **Ingress**
   - [ ] an Ingress for `capstone.localtest.me` -> `frontend` (and, if an ingress controller runs, `http://capstone.localtest.me/api/items` works)
10. **Backups**
    - [ ] CronJob `db-backup` writes `pg_dump` output to a PVC, and a run started from it completes
11. **Persistence**
    - [ ] after deleting pod `db-0`, the recreated pod still has the data

Bonus (not checked, but expected of production work): Kustomize layout
(base + overlay), config changes trigger rollouts automatically, images
pinned by digest, spread across zones, sensible rollout strategy.

### Hints

<details>
<summary>Order of work</summary>

Namespace (with PSA labels) -> Secret -> DB Service + StatefulSet -> seed Job
-> backend -> frontend -> Ingress -> backup CronJob -> PDB/HPA -> NetworkPolicies
last (it's much easier to debug connectivity *before* you lock it down, then
re-run `verify.sh` after each policy).
</details>

<details>
<summary>PostgreSQL as non-root with a read-only root filesystem</summary>

* The alpine image's `postgres` user is uid/gid **70**.
* Set `PGDATA` to a **subdirectory** of the volume mount
  (`/var/lib/postgresql/data/pgdata`): `initdb` must own its data directory
  with mode 0700, which it can't do to the mount root.
* Writable `emptyDir`s are needed for `/var/run/postgresql` (socket, lock)
  and `/tmp`.
* `pg_isready` makes a good startup/readiness/liveness probe (exec). Give the
  first start (initdb) time with a `startupProbe`.
* `POSTGRES_PASSWORD` is only read when the data directory is empty.
</details>

<details>
<summary>nginx as non-root (module 15)</summary>

uid 101, port 8080, `emptyDir`s on `/var/cache/nginx`, `/var/run`, `/tmp`;
mount the server config into `/etc/nginx/conf.d/` and the page into
`/usr/share/nginx/html/`.
</details>

<details>
<summary>Waiting for the database in the seed Job</summary>

`until pg_isready -q -t 2; do sleep 2; done` before running
`psql -v ON_ERROR_STOP=1 -f /seed/seed.sql`. Bound the wait with
`activeDeadlineSeconds` so it fails visibly instead of hanging. The Job's pod
needs the same `PG*` env vars as the backend.
</details>

<details>
<summary>NetworkPolicies</summary>

* Policies are allow-lists and they add up. Start with one policy that
  selects all pods (`podSelector: {}`) with both `policyTypes` and no rules.
* Then allow DNS egress to `kube-system` pods labelled `k8s-app: kube-dns`
  on UDP **and** TCP 53.
* A shared label such as `db-access: "true"` on the backend, seed Job and
  backup pods keeps the database policy short.
* `kubectl port-forward` is not affected by NetworkPolicies, so you can always
  test the app that way. Test the policies with `kubectl exec` from the pods:
  `wget -qO- -T 3 http://backend:8080/healthz` (frontend image), `nc -z -w 3 db 5432`.
* Policies only work if your CNI enforces them - see [module 13](../13-network-policies/README.md).
</details>

<details>
<summary>Backups</summary>

`pg_dump | gzip > /backups/<timestamp>.sql.gz` from the `postgres:16-alpine`
image, on a ReadWriteOnce PVC, with `concurrencyPolicy: Forbid`. Test it
without waiting for the schedule:
`kubectl -n lab-capstone create job --from=cronjob/db-backup db-backup-manual`.
For more on sharing one RWO volume between pods in order, see the
[RWO scenario](../../scenarios/rwo-pvc-ordered-pods/README.md).
</details>

<details>
<summary>Readiness and the database</summary>

Should the backend's readiness probe fail when the database is down?
Usually **no**: all backend pods would go unready at once, the Service
would have no endpoints, and the frontend would get errors anyway - plus you
lose the ability to serve anything that doesn't need the DB. Check the
process itself in the probe; report dependency health on a separate endpoint
(`/api/health`).
</details>

## Files

| File | What it is |
|---|---|
| [`verify.sh`](verify.sh) | the acceptance-criteria checker |
| [`solutions/base/kustomization.yaml`](solutions/base/kustomization.yaml) | reference solution base: resources, labels, ConfigMap generators for the four app files |
| [`solutions/base/01-db-service.yaml`](solutions/base/01-db-service.yaml) | headless Service `db` |
| [`solutions/base/02-db-statefulset.yaml`](solutions/base/02-db-statefulset.yaml) | PostgreSQL StatefulSet: non-root, read-only, PGDATA subdir, startup/readiness/liveness probes, PVC template |
| [`solutions/base/03-db-seed-job.yaml`](solutions/base/03-db-seed-job.yaml) | Job that waits for the DB and runs `seed.sql` |
| [`solutions/base/04-db-backup-pvc.yaml`](solutions/base/04-db-backup-pvc.yaml) | RWO PVC for dumps |
| [`solutions/base/05-db-backup-cronjob.yaml`](solutions/base/05-db-backup-cronjob.yaml) | nightly `pg_dump --clean --if-exists`, keeps 5, `concurrencyPolicy: Forbid`, `timeZone` |
| [`solutions/base/06-backend-deployment.yaml`](solutions/base/06-backend-deployment.yaml) | backend: 2 replicas, zone spread, probes, `maxUnavailable: 0` rollouts |
| [`solutions/base/07-backend-service.yaml`](solutions/base/07-backend-service.yaml) | Service `backend` :8080 |
| [`solutions/base/08-backend-pdb.yaml`](solutions/base/08-backend-pdb.yaml) / [`12-frontend-pdb.yaml`](solutions/base/12-frontend-pdb.yaml) | PodDisruptionBudgets |
| [`solutions/base/09-backend-hpa.yaml`](solutions/base/09-backend-hpa.yaml) | HPA 2-5 replicas at 70% CPU |
| [`solutions/base/10-frontend-deployment.yaml`](solutions/base/10-frontend-deployment.yaml) / [`11-frontend-service.yaml`](solutions/base/11-frontend-service.yaml) | nginx frontend |
| [`solutions/base/13-ingress.yaml`](solutions/base/13-ingress.yaml) | Ingress for `capstone.localtest.me` |
| [`solutions/base/14-networkpolicies.yaml`](solutions/base/14-networkpolicies.yaml) | default deny + DNS + per-tier allow rules |
| [`solutions/base/files/`](solutions/base/files/) | the app code (your input, see the brief) |
| [`solutions/overlays/lab/kustomization.yaml`](solutions/overlays/lab/kustomization.yaml) | the environment: Namespace, Secret generator, image digest pin, ingress class |
| [`solutions/overlays/lab/namespace.yaml`](solutions/overlays/lab/namespace.yaml) | `lab-capstone` with PSA `restricted` |
| [`solutions/overlays/lab/db.env`](solutions/overlays/lab/db.env) | demo DB credentials for the Secret generator |
| [`solutions/extras/restore-job.yaml`](solutions/extras/restore-job.yaml) | exercise 3: restore the newest dump |
| [`solutions/extras/load-generator.yaml`](solutions/extras/load-generator.yaml) | exercise 2: load generator + the NetworkPolicy it needs |

## Lab

### 1. Build it yourself

Create your own directory (outside `solutions/`), e.g. `~/capstone/`, and
work through the hints in order. Apply often; run the checker whenever you
like - it tells you what is still missing:

```bash
./modules/19-capstone/verify.sh
```

Typical first run, after creating only the namespace:

```
1. Namespace and Pod Security
  PASS namespace lab-capstone exists
  PASS namespace enforces Pod Security 'restricted'

2. Database (StatefulSet db + Secret + PVC + Service)
  FAIL StatefulSet db not found
  FAIL Service db with port 5432 not found

3. Seed Job and data
  FAIL Job db-seed missing or not succeeded
  FAIL table items has '?' rows, want >= 3

4. Backend (Deployment backend + Service + PDB + HPA)
  FAIL Deployment backend not found
...
```

Budget: 3-6 hours. Use [module 16](../16-debugging/README.md)'s triage order
whenever something doesn't come up.

### 2. Compare with the reference solution

If you want to see a complete answer (or you are stuck), deploy the
reference solution into the same namespace. If you built your own, delete
it first (`kubectl delete namespace lab-capstone`).

```bash
kubectl apply -k modules/19-capstone/solutions/overlays/lab
kubectl -n lab-capstone rollout status statefulset/db
kubectl -n lab-capstone wait --for=condition=complete job/db-seed --timeout=180s
kubectl -n lab-capstone rollout status deploy/backend
kubectl -n lab-capstone rollout status deploy/frontend
kubectl -n lab-capstone get pods,svc,pvc,ingress
```

```
NAME                           READY   STATUS      RESTARTS   AGE
pod/backend-558bbc5974-4jj7g   1/1     Running     0          4m54s
pod/backend-558bbc5974-wt627   1/1     Running     0          4m54s
pod/db-0                       1/1     Running     0          27s
pod/db-seed-8d2fw              0/1     Completed   0          4m53s
pod/frontend-c788d6f46-7qprk   1/1     Running     0          4m54s
pod/frontend-c788d6f46-v24bt   1/1     Running     0          4m54s

NAME               TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)    AGE
service/backend    ClusterIP   10.96.41.114   <none>        8080/TCP   4m54s
service/db         ClusterIP   None           <none>        5432/TCP   4m54s
service/frontend   ClusterIP   10.96.17.157   <none>        80/TCP     4m54s

NAME                               STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS
persistentvolumeclaim/data-db-0    Bound    pvc-50f41027-4b97-456f-950c-77ed9d3651aa   1Gi        RWO            standard
persistentvolumeclaim/db-backups   Bound    pvc-13cc042a-7ba7-46f6-96b9-807d7d636630   1Gi        RWO            standard

NAME                                 CLASS   HOSTS                   ADDRESS   PORTS   AGE
ingress.networking.k8s.io/capstone   nginx   capstone.localtest.me             80      4m53s
```

No PodSecurity warnings appear on apply: every pod passes `restricted`.

(Re-applying later prints `statefulset.apps/db configured` and
`poddisruptionbudget.policy/... configured` even when nothing changed.
That's cosmetic: kubectl's client-side apply always re-sends
`volumeClaimTemplates` and a PDB's `selector`, the server finds nothing to
change, and `metadata.generation` stays the same. `kubectl diff -k` shows
no differences.)

The seed Job's log shows the wait-then-seed pattern:

```bash
kubectl -n lab-capstone logs job/db-seed
```

```
2026-10-08T10:56:59+00:00 waiting for postgres at db:5432 ...
2026-10-08T10:57:05+00:00 waiting for postgres at db:5432 ...
postgres is up - seeding
CREATE TABLE
INSERT 0 3
 items
-------
     3
(1 row)
```

Use the app:

```bash
kubectl -n lab-capstone port-forward svc/frontend 8080:80
# second terminal (or open http://localhost:8080 in a browser):
curl -s localhost:8080/api/items
curl -s localhost:8080/api/health
```

```
[{"id":1,"name":"kubectl mug","price":12.50},
 {"id":2,"name":"YAML sticker pack","price":4.00},
 {"id":3,"name":"pod-shaped plushie","price":19.99}]
{"db":"up"}
```

If you have an ingress controller from [module 12](../12-ingress-gateway/README.md),
check its class with `kubectl get ingressclass` and set it in
`solutions/overlays/lab/kustomization.yaml` (the patch at the bottom), then
open <http://capstone.localtest.me/>.

### 3. Run the checker

```bash
./modules/19-capstone/verify.sh
```

Real output from the reference solution on a kind cluster (trimmed). It was
recorded on a cluster whose CNI did **not** enforce NetworkPolicies and with
no ingress controller, so it was run with `SKIP_NETPOL_ENFORCEMENT=1` and
those checks show `WARN`. On a cluster that enforces policies (recent kind
releases ship kindnet with a policy controller; if yours doesn't enforce,
use module 13's Calico option) they show `PASS`:

```
1. Namespace and Pod Security
  PASS namespace lab-capstone exists
  PASS namespace enforces Pod Security 'restricted'

2. Database (StatefulSet db + Secret + PVC + Service)
  PASS StatefulSet db ready (1/1)
  PASS db runs PostgreSQL 16 (postgres:16-alpine)
  PASS db uses volumeClaimTemplates (data)
  PASS PVC data-db-0 is Bound
  PASS credentials come from Secret(s): db-credentials
  PASS Service db exposes 5432

3. Seed Job and data
  PASS Job db-seed succeeded
  PASS table items has 3 rows

4. Backend (Deployment backend + Service + PDB + HPA)
  PASS backend has 2 available replicas
  PASS every backend container has readiness and liveness probes
  PASS Service backend exists
  PASS PodDisruptionBudget for backend: backend
  PASS HPA for backend (min/max: 2:5)
  WARN HPA has no metrics yet (is metrics-server installed? module 14)

5. Frontend (Deployment frontend + nginx config from a ConfigMap)
  PASS frontend has 2 available replicas
  PASS frontend runs nginx:1.27-alpine@sha256:65645c7bb6a0661892a8b03b89d0743208a18dd2f3f17a54ef4b76fb8e2f2a10
  PASS frontend mounts ConfigMap(s): frontend-nginx-gmhkgt5tc8 frontend-html-5dgt964dcb
  PASS Service frontend exists

6. Resources and security context on every workload container
  PASS all 5 containers set requests.cpu, requests.memory and limits.memory
  PASS all containers use readOnlyRootFilesystem
  PASS all containers set allowPrivilegeEscalation: false

7. End to end through the frontend (via kubectl port-forward)
  PASS GET / -> 200
  PASS GET /api/items returns 3 items from the database

8. NetworkPolicies
  PASS default-deny policy for ingress+egress: default-deny-all
  PASS DNS works from frontend
  PASS frontend -> backend:8080 allowed
  PASS backend -> db:5432 allowed
  WARN frontend -> db:5432 is OPEN (should be blocked; is a policy missing, or does your CNI not enforce NetworkPolicy? module 13)
  WARN backend -> frontend:80 is OPEN (backend should only talk to db and DNS)

9. Ingress
  PASS Ingress routes capstone.localtest.me to Service frontend
  WARN http://capstone.localtest.me/api/items -> 000 (no ingress controller on localhost:80? module 12)

10. Backups (CronJob db-backup)
  PASS CronJob db-backup writes to PVC db-backups
  PASS a backup run from the CronJob completed: backup written: /backups/capstone-20261008T111642Z.sql.gz (728 bytes)

11. Data survives a database pod restart
  PASS db-0 was recreated and still has 3 rows

Result: 32 passed, 0 failed, 4 warnings
```

The script exits 0 only when nothing failed, so you can use it in CI. Knobs:
`SKIP_PERSISTENCE=1` (don't delete `db-0`), `SKIP_NETPOL_ENFORCEMENT=1`,
`INGRESS_URL=...`, `NS=...`.

### 4. Review: why the reference solution looks the way it does

Read the comments in the solution files; the key decisions:

* **StatefulSet, not Deployment, for PostgreSQL** - stable name `db-0`, its own
  PVC that outlives the pod, never two instances on one data directory. For
  real production data use an operator (e.g. CloudNativePG).
* **Readiness doesn't depend on the database** (see the last hint).
* **`maxUnavailable: 0` rolling updates + PDBs + topology spread** - capacity
  never drops during rollouts, drains, or the loss of one zone.
* **Generated, hashed ConfigMaps** (Kustomize) - editing `api.sh`,
  `default.conf` or `index.html` automatically rolls the right Deployment.
  Two generated objects are deliberately *not* hashed: `db-seed` (a Job's pod
  template is immutable) and `db-credentials` (PostgreSQL only reads
  `POSTGRES_PASSWORD` on first init, so a rollout on change would be a lie).
* **One shared `db-access` label** gives the three DB clients egress to,
  and the DB ingress from, exactly each other.
* **Backups next to the database are not backups** - they only protect against
  logical mistakes. Copy them off the cluster (exercise 3).

## Exercises

1. **Change the app, watch it roll.** Add a fourth product to `seed.sql` and
   change the heading in `index.html`. Re-apply the overlay. Which objects
   change (`kubectl diff -k` first)? Does the seed Job run again? Why not, and
   how do you make it run?
   *Answer:* `frontend-html-<hash>` is a new ConfigMap, so the frontend rolls
   out; `db-seed` is updated in place (it is deliberately generated *without* a
   hash - a Job's pod template is immutable, so a new name would make every
   later apply fail). A finished Job never runs again: delete it and re-apply
   (`kubectl -n lab-capstone delete job db-seed && kubectl apply -k ...`); the
   log then ends with `4` rows.

2. **Load test the HPA.** With metrics-server installed (module 14), generate
   load on `/api/items` from a pod inside the namespace (remember your
   NetworkPolicies - the load generator needs to be allowed to reach the
   frontend or backend) and watch `kubectl get hpa -w`. What limits how far
   it scales?
   Solution: [`solutions/extras/load-generator.yaml`](solutions/extras/load-generator.yaml).

3. **Restore drill.** Delete all rows (`kubectl -n lab-capstone exec db-0 -- psql -U shop -d shop -c 'DELETE FROM items'`),
   then restore from the newest dump in the `db-backups` PVC with a one-off Job
   (`gunzip -c <file> | psql`). Which pod can mount the RWO backup volume, and
   on which node must it run?
   Solution: [`solutions/extras/restore-job.yaml`](solutions/extras/restore-job.yaml)
   (its header has the commands and the answers).

4. **Rotate the database password** without losing data. Changing `db.env`
   alone is not enough - why? (Hint: `POSTGRES_PASSWORD` is only read on first
   init.) Plan the steps: `ALTER USER`, new Secret, rolling restart of the
   clients.

5. **Helm it.** Turn the solution into a Helm chart (module 18) with values
   for replica counts, the ingress host/class and resources, plus a
   `helm test` that calls `/api/items`.

6. **Stretch: Gateway API.** Replace the Ingress with a Gateway API
   `HTTPRoute` attached to the Gateway from [module 12](../12-ingress-gateway/README.md),
   and update `verify.sh` section 9 accordingly.

## Cleanup

```bash
kubectl delete -k modules/19-capstone/solutions/overlays/lab   # reference solution
kubectl delete namespace lab-capstone --ignore-not-found        # or your own build
```

Deleting the namespace deletes the PVCs and, with the `standard`
StorageClass (`reclaimPolicy: Delete`), the data and backups too.

## Further reading

* [Run a Replicated Stateful Application](https://kubernetes.io/docs/tasks/run-application/run-replicated-stateful-application/) and [StatefulSets](https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/)
* [Configure Liveness, Readiness and Startup Probes](https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/)
* [Specifying a Disruption Budget](https://kubernetes.io/docs/tasks/run-application/configure-pdb/) and [Horizontal Pod Autoscaling](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/)
* [Network Policies](https://kubernetes.io/docs/concepts/services-networking/network-policies/)
* [CronJob](https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/) (incl. `timeZone`, `concurrencyPolicy`)
* [Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
* [Production environment considerations](https://kubernetes.io/docs/setup/production-environment/)
* The official [postgres image docs](https://hub.docker.com/_/postgres) (env vars, `PGDATA`, running as an arbitrary user)
