# Module 08 – Jobs & CronJobs

## Goal

Run work that has an end (batch processing, migrations, reports, backups)
reliably, in parallel when that helps, with sensible retry and cleanup rules,
and on a schedule.

## What you'll learn

* Job basics, `completions` and `parallelism`.
* Failure handling: `backoffLimit`, `restartPolicy` `Never` vs `OnFailure`,
  `activeDeadlineSeconds`, `podFailurePolicy`, `backoffLimitPerIndex`.
* Indexed Jobs and `JOB_COMPLETION_INDEX`; the work-queue pattern.
* `ttlSecondsAfterFinished`, `suspend`, and `kubectl wait --for=condition=complete`.
* CronJobs: `schedule`, `timeZone`, `concurrencyPolicy` (Allow / Forbid /
  Replace), `startingDeadlineSeconds`, history limits, and
  `kubectl create job --from=cronjob/...`.
* A Job as a one-time migration/seed step before an app starts.

## Concepts

### Job vs Deployment

| | Deployment | Job |
|---|---|---|
| Goal | keep N pods **running** forever | get N pods to **succeed** (exit 0), then stop |
| Pod exits 0 | restarted (it "crashed") | counted as a success, not restarted |
| `restartPolicy` | `Always` | `Never` or `OnFailure` (`Always` is rejected) |
| When it's done | never | `Complete` or `Failed` condition, pods kept for logs |

The Job controller labels its pods `batch.kubernetes.io/job-name=<job>` (and
`batch.kubernetes.io/controller-uid`), which is how `kubectl logs job/<name>`
finds them.

### Job patterns

| Pattern | Settings | Each pod knows… | Done when |
|---|---|---|---|
| Single run | (defaults) | nothing | 1 pod succeeded |
| Fixed count | `completions: N`, `parallelism: P` | nothing (pods are identical) | N pods succeeded |
| **Indexed** | `completionMode: Indexed`, `completions: N` | its index `0…N-1` (`JOB_COMPLETION_INDEX`) | every index has succeeded |
| **Work queue** | `parallelism: P`, **no** `completions` | nothing; pulls work from a queue | ≥ 1 pod succeeded and all pods have exited |

* **Indexed**: static partitioning. Index *i* processes shard *i*, frames
  *i×100 … i×100+99*, test partition *i*. No queue service needed. Each index
  is retried on its own. Pods get the hostname `<job>-<index>`, and with a
  headless Service + `subdomain` they can reach each other by name
  (exercise 6).
* **Work queue**: dynamic load balancing. Workers pop items from a queue
  (Redis, RabbitMQ, SQS…) until it's empty and then exit 0. Fast workers
  take more items. Because `completions` is unset, the Job completes once a
  worker has succeeded and all workers have stopped, which means "the queue
  is drained". The catch: an item popped by a worker that then crashes is
  lost unless the queue supports acknowledgements or leases (exercise 2).

### When things fail

| Knob | Effect |
|---|---|
| `restartPolicy: Never` | every failed attempt is a **new pod**. Failed pods are kept, so you can read every attempt's logs. |
| `restartPolicy: OnFailure` | the kubelet restarts the **container in the same pod** (CrashLoopBackOff). Fewer pods, but when the Job gives up the pod is deleted, and its logs with it. |
| `backoffLimit` (default 6) | failed attempts allowed before the Job is `Failed` (reason `BackoffLimitExceeded`). Retries back off exponentially: 10s, 20s, 40s… capped at 6 minutes. |
| `activeDeadlineSeconds` | hard wall-clock limit for the whole Job, retries included (reason `DeadlineExceeded`). It wins over `backoffLimit`. |
| `podFailurePolicy` | rules by **exit code** or **pod condition**: `FailJob` (don't bother retrying), `Ignore` (retry without counting, e.g. node drain/preemption via the `DisruptionTarget` condition), `FailIndex`, `Count`. Needs `restartPolicy: Never`. |
| `backoffLimitPerIndex` + `maxFailedIndexes` | Indexed Jobs only. Each index gets its own retry budget, so one bad shard can't fail the others. The status lists `completedIndexes` and `failedIndexes`. |
| `podReplacementPolicy: Failed` | create a replacement only once the old pod has fully terminated, not while it's still shutting down. Use it when two copies of the same work must never overlap. |
| `successPolicy` | Indexed Jobs only. Declare success early, for example "index 0 succeeded" (exercise 4). |

**Conditions.** A finishing Job first gets an interim condition,
`SuccessCriteriaMet` or `FailureTarget`, while its remaining pods are
stopped. Then it gets the final `Complete` or `Failed`. Pipelines usually wait
for the final one:

```bash
kubectl wait --for=condition=complete job/<name> --timeout=120s   # exits non-zero on timeout
kubectl wait --for=condition=failed   job/<name> --timeout=120s
```

### Cleaning up finished Jobs

Finished Jobs and their pods stay forever unless something removes them:

* `ttlSecondsAfterFinished: N` on a Job: deleted N seconds after it
  completes **or** fails.
* `successfulJobsHistoryLimit` (default 3) and `failedJobsHistoryLimit`
  (default 1) on a CronJob: older Jobs it created are deleted.

A Job's pod template is **immutable**, and Job names must be unique. To re-run a
Job, delete and re-create it (`kubectl replace --force -f job.yaml`), or give
every run a new name (CI systems often use `metadata.generateName` with
`kubectl create`).

### CronJobs

A CronJob is a Job **factory**. At every scheduled time it creates a Job from
`jobTemplate`, named `<cronjob>-<scheduled time in minutes since the epoch>`.
That suffix is why CronJob names are limited to 52 characters.

| Field | Meaning |
|---|---|
| `schedule` | 5-field cron: `minute hour day-of-month month day-of-week`, e.g. `"30 2 * * 1-5"`, or macros like `@daily` |
| `timeZone` | IANA zone such as `"Europe/Berlin"`. Without it, the controller manager's local time zone is used. `CRON_TZ=` inside `schedule` is rejected. |
| `concurrencyPolicy` | `Allow` (default): overlapping runs are fine. `Forbid`: skip a run while the previous one is active. `Replace`: delete the active run and start the new one. |
| `startingDeadlineSeconds` | how late a run may still start (controller down, Forbid blocking). Later than that and it's counted as missed. Without it, if more than 100 schedules were missed (after a long outage, say), the controller refuses to start the Job and logs an error. |
| `successfulJobsHistoryLimit` / `failedJobsHistoryLimit` | how many finished Jobs to keep |
| `suspend` | pause future runs (running Jobs are not touched) |

Each scheduled Job carries the annotation
`batch.kubernetes.io/cronjob-scheduled-timestamp`, the time it was *meant* to
run.

**Cron jobs must be idempotent.** The controller aims for "about once per
schedule": a run can be skipped (missed deadline, `Forbid`) and, in rare
failure cases, can happen twice. A nightly report that runs twice should not
send two invoices.

### A Job as a migration / seed step

"Run the database migration, *then* start the new app version" is a classic
use of a Job:

1. The Job **waits for its dependency** (the database) instead of failing and
   burning retries.
2. It is **idempotent**. Migration tools (Flyway, Liquibase, Alembic…) record
   which migrations already ran.
3. Something **gates the app on it**: the deploy pipeline runs
   `kubectl wait --for=condition=complete job/migrate`, a Helm
   `pre-install`/`pre-upgrade` hook, an Argo CD `PreSync` hook, or an init
   container in the app that waits for the Job (exercise 3).

When the migration and the app have to share one ReadWriteOnce volume, one
after the other, see
[`../../scenarios/rwo-pvc-ordered-pods/README.md`](../../scenarios/rwo-pvc-ordered-pods/README.md).

## Files

| File | What it demonstrates |
|---|---|
| [`00-namespace.yaml`](00-namespace.yaml) | the `lab-jobs` namespace |
| [`01-job-hello.yaml`](01-job-hello.yaml) | a single-run Job |
| [`02-job-parallel.yaml`](02-job-parallel.yaml) | `completions: 6`, `parallelism: 2` |
| [`03-job-fail-never.yaml`](03-job-fail-never.yaml) | `backoffLimit` with `restartPolicy: Never`: failed pods pile up |
| [`04-job-fail-onfailure.yaml`](04-job-fail-onfailure.yaml) | the same with `OnFailure`: one pod, restarting containers |
| [`05-job-deadline.yaml`](05-job-deadline.yaml) | `activeDeadlineSeconds` |
| [`06-job-ttl.yaml`](06-job-ttl.yaml) | `ttlSecondsAfterFinished` |
| [`07-job-indexed.yaml`](07-job-indexed.yaml) | Indexed Job, `JOB_COMPLETION_INDEX` |
| [`08-job-pod-failure-policy.yaml`](08-job-pod-failure-policy.yaml) | `podFailurePolicy`: fail fast on exit code 42, ignore disruptions |
| [`09-job-backoff-per-index.yaml`](09-job-backoff-per-index.yaml) | `backoffLimitPerIndex` + `maxFailedIndexes` |
| [`10-job-suspend.yaml`](10-job-suspend.yaml) | a suspended Job |
| [`11-cronjob.yaml`](11-cronjob.yaml) | CronJob `report`: schedule, `timeZone`, `Forbid`, deadlines, history |
| [`12-cronjob-concurrency.yaml`](12-cronjob-concurrency.yaml) | CronJob `slow` whose runs overlap: Allow vs Forbid vs Replace |
| [`13-redis.yaml`](13-redis.yaml) | a small Redis used by the seed Job and the work-queue exercise |
| [`14-job-seed.yaml`](14-job-seed.yaml) | a one-time, idempotent seed/migration Job |
| [`solutions/`](solutions/) | reference answers for the exercises |

## Lab

```bash
cd modules/08-jobs-cronjobs
kubectl apply -f 00-namespace.yaml
```

Start the two CronJobs now. They need a few minutes to show interesting
behaviour, and you'll come back to them in steps 11 and 12:

```bash
kubectl apply -f 11-cronjob.yaml -f 12-cronjob-concurrency.yaml
```

### 1. Hello, Job

```bash
kubectl apply -f 01-job-hello.yaml
kubectl wait -n lab-jobs --for=condition=complete job/hello --timeout=60s
kubectl get job hello -n lab-jobs
kubectl get pods -n lab-jobs -l app=hello
kubectl logs -n lab-jobs job/hello
kubectl get job hello -n lab-jobs -o jsonpath='{range .status.conditions[*]}{.type}={.status} {end}'; echo
```

```
job.batch/hello condition met
NAME    STATUS     COMPLETIONS   DURATION   AGE
hello   Complete   1/1           7s         7s
NAME          READY   STATUS      RESTARTS   AGE
hello-rx2w7   0/1     Completed   0          7s
Hello from hello-rx2w7
sum(1..1000) = 500500
SuccessCriteriaMet=True Complete=True
```

The pod is `Completed` and stays around so you can read its logs.
`kubectl wait` is how scripts and pipelines block until a Job is done.

Quick way to generate a Job manifest:
`kubectl create job pi -n lab-jobs --image=busybox:1.37 --dry-run=client -o yaml -- sh -c 'echo hi'`.

### 2. completions and parallelism

```bash
kubectl apply -f 02-job-parallel.yaml
kubectl wait -n lab-jobs --for=condition=complete job/parallel --timeout=120s
kubectl logs -n lab-jobs -l app=parallel --prefix | sort -k2
kubectl get job parallel -n lab-jobs
```

```
[pod/parallel-44qc7/worker] 10:50:11 parallel-44qc7 working
[pod/parallel-h56hm/worker] 10:50:11 parallel-h56hm working
[pod/parallel-5w69s/worker] 10:50:20 parallel-5w69s working
[pod/parallel-bf7nc/worker] 10:50:20 parallel-bf7nc working
[pod/parallel-65n8l/worker] 10:50:29 parallel-65n8l working
[pod/parallel-thdpn/worker] 10:50:29 parallel-thdpn working
NAME       STATUS     COMPLETIONS   DURATION   AGE
parallel   Complete   6/6           27s        27s
```

Three waves of two pods, about 9 seconds apart: 6 completions, never more
than 2 at a time.

### 3. Retries: Never vs OnFailure

Watch in a second terminal:

```bash
kubectl get pods -n lab-jobs -l 'app in (fail-never,fail-onfailure)' -w
```

Then:

```bash
kubectl apply -f 03-job-fail-never.yaml -f 04-job-fail-onfailure.yaml
kubectl wait -n lab-jobs --for=condition=failed job/fail-never job/fail-onfailure --timeout=240s
kubectl get jobs,pods -n lab-jobs -l 'app in (fail-never,fail-onfailure)'
kubectl logs -n lab-jobs -l app=fail-never --prefix
```

```
NAME                       STATUS   COMPLETIONS   DURATION   AGE
job.batch/fail-never       Failed   0/1           36s        36s
job.batch/fail-onfailure   Failed   0/1           36s        36s

NAME                   READY   STATUS   RESTARTS   AGE
pod/fail-never-hsh9x   0/1     Error    0          36s
pod/fail-never-nppjq   0/1     Error    0          25s
pod/fail-never-nzfs8   0/1     Error    0          4s

[pod/fail-never-hsh9x/flaky] 10:50:45 attempt in pod fail-never-hsh9x
[pod/fail-never-nppjq/flaky] 10:50:56 attempt in pod fail-never-nppjq
[pod/fail-never-nzfs8/flaky] 10:51:17 attempt in pod fail-never-nzfs8
```

* **`Never`**: three pods (1 try + `backoffLimit: 2` retries), each one kept.
  The gaps between attempts (about 10s, then 20s) are the exponential
  back-off.
* **`OnFailure`**: no pod left at all. The watch showed one pod restarting its
  container (`RESTARTS 1`, `CrashLoopBackOff`, `RESTARTS 2`), and then the
  Job controller deleted it:

  ```bash
  kubectl get events -n lab-jobs --field-selector involvedObject.name=fail-onfailure
  ```

  ```
  Normal    SuccessfulCreate       job/fail-onfailure   Created pod: fail-onfailure-gs8cv
  Normal    SuccessfulDelete       job/fail-onfailure   Deleted pod: fail-onfailure-gs8cv
  Warning   BackoffLimitExceeded   job/fail-onfailure   Job has reached the specified backoff limit
  ```

```bash
kubectl get job fail-never -n lab-jobs -o jsonpath='{range .status.conditions[*]}{.type}={.status} reason={.reason}{"\n"}{end}'
```

```
FailureTarget=True reason=BackoffLimitExceeded
Failed=True reason=BackoffLimitExceeded
```

### 4. A deadline for the whole Job

```bash
kubectl apply -f 05-job-deadline.yaml
kubectl wait -n lab-jobs --for=condition=failed job/deadline --timeout=60s
kubectl get job deadline -n lab-jobs
kubectl get job deadline -n lab-jobs -o jsonpath='{range .status.conditions[*]}{.type}={.status} reason={.reason} msg={.message}{"\n"}{end}'
```

```
NAME       STATUS   COMPLETIONS   DURATION   AGE
deadline   Failed   0/1           16s        16s
FailureTarget=True reason=DeadlineExceeded msg=Job was active longer than specified deadline
Failed=True reason=DeadlineExceeded msg=Job was active longer than specified deadline
```

The 60-second task was killed after 15 seconds. The final `Failed` condition
appears only once the pod has actually terminated. That's why the manifest
traps SIGTERM: without the trap, the shell would ignore the signal and the Job
would take another 30 seconds (the grace period) to be marked `Failed`.

### 5. Self-cleaning Jobs

```bash
kubectl apply -f 06-job-ttl.yaml
kubectl wait -n lab-jobs --for=condition=complete job/ttl-demo
kubectl logs -n lab-jobs job/ttl-demo
# ... wait 20 seconds ...
kubectl get job ttl-demo -n lab-jobs
```

```
finished - this Job deletes itself 20s from now
Error from server (NotFound): jobs.batch "ttl-demo" not found
```

### 6. Indexed Job

```bash
kubectl apply -f 07-job-indexed.yaml
kubectl wait -n lab-jobs --for=condition=complete job/indexed
kubectl logs -n lab-jobs -l app=indexed --prefix | sort -t' ' -k3
kubectl get pods -n lab-jobs -l app=indexed \
  -o custom-columns='NAME:.metadata.name,INDEX:.metadata.labels.batch\.kubernetes\.io/job-completion-index,HOSTNAME:.spec.hostname'
kubectl get job indexed -n lab-jobs -o jsonpath='{.status.completedIndexes}'; echo
```

```
[pod/indexed-0-z9lm9/worker] index 0 on indexed-0 processes: apple
[pod/indexed-1-srzbt/worker] index 1 on indexed-1 processes: banana
[pod/indexed-2-dmjqc/worker] index 2 on indexed-2 processes: cherry
[pod/indexed-3-n7spl/worker] index 3 on indexed-3 processes: date
[pod/indexed-4-kc6q9/worker] index 4 on indexed-4 processes: elderberry
NAME              INDEX   HOSTNAME
indexed-0-z9lm9   0       indexed-0
indexed-1-srzbt   1       indexed-1
...
0-4
```

Every pod got a different item from the list just by reading
`JOB_COMPLETION_INDEX`. Pod names and hostnames include the index.

### 7. podFailurePolicy: fail fast on a non-retriable error

```bash
kubectl apply -f 08-job-pod-failure-policy.yaml
kubectl wait -n lab-jobs --for=condition=failed job/pod-failure-policy --timeout=60s
kubectl get job,pods -n lab-jobs -l app=pod-failure-policy
kubectl get job pod-failure-policy -n lab-jobs -o jsonpath='{.status.conditions[-1:].message}'; echo
```

```
NAME                           STATUS   COMPLETIONS   DURATION   AGE
job.batch/pod-failure-policy   Failed   0/1           4s         4s
NAME                           READY   STATUS   RESTARTS   AGE
pod/pod-failure-policy-rgqfc   0/1     Error    0          5s
Container main for pod lab-jobs/pod-failure-policy-rgqfc failed with exit code 42 matching FailJob rule at index 0
```

`backoffLimit` is 6, yet there was exactly **one** attempt. Exit code 42 says
"retrying won't help", so the Job failed in 4 seconds instead of retrying for
minutes.

### 8. backoffLimitPerIndex

```bash
kubectl apply -f 09-job-backoff-per-index.yaml
kubectl wait -n lab-jobs --for=condition=failed job/per-index --timeout=120s
kubectl get pods -n lab-jobs -l app=per-index
kubectl get job per-index -n lab-jobs \
  -o jsonpath='completed={.status.completedIndexes} failed={.status.failedIndexes}{"\n"}{.status.conditions[-1:].reason}{"\n"}'
```

```
NAME                READY   STATUS      RESTARTS   AGE
per-index-0-nxljj   0/1     Completed   0          58s
per-index-1-24fdf   0/1     Completed   0          58s
per-index-2-tggq7   0/1     Error       0          46s
per-index-2-tpmw8   0/1     Error       0          58s
per-index-3-n7mt9   0/1     Completed   0          58s
completed=0,1,3 failed=2
FailedIndexes
```

Index 2 used up its own budget (1 try + 1 retry). Indexes 0, 1 and 3 still
ran to completion, and the status tells you exactly which shard to fix and
re-run.

### 9. Suspend and resume

```bash
kubectl apply -f 10-job-suspend.yaml
kubectl get job suspended -n lab-jobs
kubectl get pods -n lab-jobs -l app=suspended
kubectl patch job suspended -n lab-jobs --type merge -p '{"spec":{"suspend":false}}'
kubectl wait -n lab-jobs --for=condition=complete job/suspended
kubectl get job suspended -n lab-jobs
```

```
NAME        STATUS      COMPLETIONS   DURATION   AGE
suspended   Suspended   0/3                      0s
No resources found in lab-jobs namespace.
job.batch/suspended patched
job.batch/suspended condition met
NAME        STATUS     COMPLETIONS   DURATION   AGE
suspended   Complete   3/3           6s         6s
```

### 10. A seed/migration Job that waits for its database

Start the Job **before** the database exists, to see it wait:

```bash
kubectl apply -f 14-job-seed.yaml
kubectl logs -n lab-jobs job/seed-redis --tail=2
```

```
Could not connect to Redis at redis:6379: Name does not resolve
waiting for redis...
```

Now create the database. The Job carries on by itself:

```bash
kubectl apply -f 13-redis.yaml
kubectl wait -n lab-jobs --for=condition=complete job/seed-redis --timeout=120s
kubectl logs -n lab-jobs job/seed-redis --tail=4
kubectl exec -n lab-jobs deploy/redis -- redis-cli mget schema_version config:currency config:max_cart_items
```

```
job.batch/seed-redis condition met
OK
OK
OK
seed done, schema_version=3
3
EUR
50
```

Run it again. It's idempotent, so `SET ... NX` writes nothing (redis-cli
prints an empty line for each "not written"):

```bash
kubectl delete job seed-redis -n lab-jobs
kubectl apply -f 14-job-seed.yaml
kubectl wait -n lab-jobs --for=condition=complete job/seed-redis
kubectl logs -n lab-jobs job/seed-redis
```

You also can't just "edit and re-apply" a Job to run it again. Try changing
its image with `kubectl patch`: `The Job "seed-redis" is invalid:
spec.template: ... field is immutable`. Delete and re-create it instead.

### 11. CronJob basics

By now `report` has run a few times:

```bash
kubectl get cronjob report -n lab-jobs
kubectl get jobs -n lab-jobs -l app=report
kubectl logs -n lab-jobs -l app=report --prefix
kubectl get jobs -n lab-jobs -l app=report \
  -o jsonpath='{range .items[*]}{.metadata.name} {.metadata.annotations.batch\.kubernetes\.io/cronjob-scheduled-timestamp}{"\n"}{end}'
```

```
NAME     SCHEDULE      TIMEZONE   SUSPEND   ACTIVE   LAST SCHEDULE   AGE
report   */1 * * * *   Etc/UTC    False     0        52s             5m33s
NAME              STATUS     COMPLETIONS   DURATION   AGE
report-29857616   Complete   1/1           3s         2m10s
report-29857617   Complete   1/1           4s         70s
report-29857618   Complete   1/1           4s         10s
...
report-29857617 2026-10-08T10:57:00Z
report-29857618 2026-10-08T10:58:00Z
```

Never more than 3 successful Jobs (`successfulJobsHistoryLimit: 3`). The
number in each name is the scheduled time in minutes since the Unix epoch.

Run it **now**, outside the schedule. This is handy for testing a CronJob
or re-running last night's failed backup:

```bash
kubectl create job report-manual --from=cronjob/report -n lab-jobs
kubectl wait -n lab-jobs --for=condition=complete job/report-manual
kubectl logs -n lab-jobs job/report-manual
kubectl get job report-manual -n lab-jobs -o jsonpath='{.metadata.annotations}'; echo
```

```
report generated at 10:58:20 by report-manual-nkgwf
{"cronjob.kubernetes.io/instantiate":"manual"}
```

The manual Job is owned by the CronJob, so it is deleted together with it.

### 12. concurrencyPolicy: Allow, Forbid, Replace

`slow` fires every minute, but each run takes 150 seconds. With the default
`Allow`, runs pile up. After about 3 minutes:

```bash
kubectl get cronjob slow -n lab-jobs
kubectl get jobs -n lab-jobs -l app=slow
```

```
NAME   SCHEDULE      TIMEZONE   SUSPEND   ACTIVE   LAST SCHEDULE   AGE
slow   */1 * * * *   Etc/UTC    False     3        29s             3m27s
NAME            STATUS    COMPLETIONS   DURATION   AGE
slow-29857614   Running   0/1           2m29s      2m29s
slow-29857615   Running   0/1           89s        89s
slow-29857616   Running   0/1           29s        29s
```

Switch to **Forbid** and wait for the next full minute:

```bash
kubectl patch cronjob slow -n lab-jobs -p '{"spec":{"concurrencyPolicy":"Forbid"}}'
# after the next minute boundary:
kubectl get events -n lab-jobs --field-selector involvedObject.name=slow | tail -2
```

```
Normal   SawCompletedJob    cronjob/slow   Saw completed job: slow-29857614, condition: Complete
Normal   JobAlreadyActive   cronjob/slow   Not starting job because prior execution is running and concurrency policy is Forbid
```

Switch to **Replace**:

```bash
kubectl patch cronjob slow -n lab-jobs -p '{"spec":{"concurrencyPolicy":"Replace"}}'
# after the next minute boundary:
kubectl get jobs -n lab-jobs -l app=slow
kubectl get events -n lab-jobs --field-selector involvedObject.name=slow | tail -5
```

```
NAME            STATUS     COMPLETIONS   DURATION   AGE
slow-29857614   Complete   1/1           2m33s      4m10s
slow-29857618   Running    0/1           10s        10s
...
Normal   SuccessfulDelete   cronjob/slow   Deleted job slow-29857615
Normal   SuccessfulDelete   cronjob/slow   Deleted job slow-29857616
Normal   SuccessfulCreate   cronjob/slow   Created job slow-29857617
Normal   SuccessfulDelete   cronjob/slow   Deleted job slow-29857617
Normal   SuccessfulCreate   cronjob/slow   Created job slow-29857618
```

The active runs were killed and replaced. Note `slow-29857617`: that's the
run `Forbid` had skipped. `slow` has no `startingDeadlineSeconds`, so the
controller caught it up as soon as the policy allowed. `report` sets
`startingDeadlineSeconds: 30` to prevent exactly this kind of late start.

Stop the noise:

```bash
kubectl patch cronjob slow -n lab-jobs -p '{"spec":{"suspend":true}}'
```

## Exercises

1. **How many tries?** Write a Job whose pod fails about half the time
   (exit 1) and succeeds otherwise, with `backoffLimit: 4`. Run it a few
   times. How many pods do you see per run? What is the chance the Job fails?
   *Hint:* `awk 'BEGIN { srand(); print int(rand()*100) }'` gives you a
   random number in busybox. Solution:
   [`solutions/01-flaky-job.yaml`](solutions/01-flaky-job.yaml)
   (the Job fails only after 5 failures in a row: 1/32).

2. **Work queue.** Push the numbers 1–12 into a Redis list (`redis-cli rpush
   queue ...` via `kubectl exec deploy/redis`), then write a Job with 3
   parallel workers that pop items until the list is empty. Why must
   `completions` stay unset?
   *Hint:* `redis-cli -h redis LPOP queue` prints nothing when the list is
   empty. Solution: [`solutions/02-work-queue.yaml`](solutions/02-work-queue.yaml).
   Here each worker processed 4 items and the Job showed `COMPLETIONS 3/1 of 3`.

3. **Gate the app on the seed Job.** Make a Deployment whose pods don't start
   until `job/seed-redis` is Complete, without any external script.
   *Hint:* an init container with `rancher/kubectl:v1.36.2` running
   `kubectl wait`, plus a ServiceAccount allowed to `get`/`list`/`watch` Jobs.
   Solution: [`solutions/03-wait-for-seed.yaml`](solutions/03-wait-for-seed.yaml).
   Delete `seed-redis` first, apply the solution (the pod sits in
   `Init:0/1`), then apply `14-job-seed.yaml` and watch the app start.

4. **Done when the leader is done.** An Indexed Job has 4 indexes. Index 0
   finishes in 5s, the others would take 5 minutes. Make the Job `Complete`
   as soon as index 0 succeeds.
   *Hint:* `spec.successPolicy.rules[].succeededIndexes`. Solution:
   [`solutions/04-success-policy.yaml`](solutions/04-success-policy.yaml)
   (completes in about 10s with `reason=SuccessPolicy`, and the other pods are
   stopped).

5. **TTL vs history.** Add `ttlSecondsAfterFinished: 10` to `report`'s
   `jobTemplate`
   (`kubectl patch cronjob report -n lab-jobs --type merge -p '{"spec":{"jobTemplate":{"spec":{"ttlSecondsAfterFinished":10}}}}'`).
   What does `kubectl get jobs -l app=report` show a few minutes later? Which
   mechanism wins? Then undo it. Does `kubectl apply -f 11-cronjob.yaml` undo
   it, and why not?
   *Hint:* new Jobs disappear 10s after finishing, so the history limit never
   gets to keep three. `apply` only removes fields it set itself (the
   last-applied annotation). Use
   `kubectl patch cronjob report -n lab-jobs --type json -p '[{"op":"remove","path":"/spec/jobTemplate/spec/ttlSecondsAfterFinished"}]'`.

6. **Indexed pods that talk to each other.** Create an Indexed Job with 3
   indexes where index 0 serves a file over HTTP (`busybox httpd`) and indexes
   1 and 2 download it from `mesh-0.mesh`.
   *Hint:* a headless Service named `mesh` and `spec.subdomain: mesh` in the
   pod template. Pods without a readiness probe need
   `publishNotReadyAddresses: true`. Solution:
   [`solutions/06-indexed-with-dns.yaml`](solutions/06-indexed-with-dns.yaml).

## Cleanup

```bash
kubectl delete namespace lab-jobs
```

This module creates no cluster-scoped objects.

## Further reading

* [Jobs](https://kubernetes.io/docs/concepts/workloads/controllers/job/): completion modes, failure policies, success policy, suspend
* [Handling retriable and non-retriable pod failures with Pod failure policy](https://kubernetes.io/docs/tasks/job/pod-failure-policy/)
* [Indexed Job for parallel processing with static work assignment](https://kubernetes.io/docs/tasks/job/indexed-parallel-processing-static/)
* [Fine parallel processing using a work queue](https://kubernetes.io/docs/tasks/job/fine-parallel-processing-work-queue/)
* [Automatic cleanup for finished Jobs](https://kubernetes.io/docs/concepts/workloads/controllers/ttlafterfinished/)
* [CronJob](https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/)
* [Running automated tasks with a CronJob](https://kubernetes.io/docs/tasks/job/automated-tasks-with-cron-jobs/)
