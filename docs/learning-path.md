# Learning path

The roadmap through this course: four phases, each with goals, the modules
it covers, a time estimate, a checklist of concrete skills, and a milestone
project that ties the phase together. The course targets **Kubernetes 1.37**
(kind v0.33.0, kubectl v1.37).

**How to use this page.** Work through the phases in order. Tick a box only
when you can do the thing **without looking at the module** (looking at
`kubectl explain` and kubernetes.io is fine, as in the exams). If you can't
tick a box, redo that part of the lab. Don't move on to the next phase
until you have finished the milestone.

* [Phase 1: Foundations (00–05)](#phase-1-foundations)
* [Phase 2: Workloads and state (06–09 + RWO scenario)](#phase-2-workloads-and-state)
* [Phase 3: Operating a cluster (10–16)](#phase-3-operating-a-cluster)
* [Phase 4: Packaging and real projects (17–19)](#phase-4-packaging-and-real-projects)
* [Suggested schedule](#suggested-schedule)
* [How to practise](#how-to-practise)
* [CKAD and CKA mapping](#ckad-and-cka-mapping)
* [Where to go next](#where-to-go-next)

```
Phase 1  Foundations            00 01 02 03 04 05            ~8–10 h  ─► Milestone 1: two-tier app
Phase 2  Workloads & state      06 07 08 09 + RWO scenario   ~6–8 h   ─► Milestone 2: stateful counter
Phase 3  Operating a cluster    10 11 12 13 14 15 16         ~10–13 h ─► Milestone 3: harden + game day
Phase 4  Packaging & projects   17 18 19                     ~6–9 h   ─► Milestone 4: ship it
                                                     total ≈ 30–40 h
```

---

## Phase 1: Foundations

**Goal:** be fluent with kubectl and the core objects, and understand how
desired state, controllers and label selectors fit together.

| # | Module | Time |
|---|---|---|
| 00 | [Setup](../modules/00-setup/README.md) | 45 min |
| 01 | [Pods](../modules/01-pods/README.md) | 2 h |
| 02 | [Namespaces & labels](../modules/02-namespaces-labels/README.md) | 1 h |
| 03 | [Deployments](../modules/03-deployments/README.md) | 1.5 h |
| 04 | [Services](../modules/04-services/README.md) | 1.5 h |
| 05 | [ConfigMaps & Secrets](../modules/05-config-secrets/README.md) | 1 h |
| | Milestone 1 | 1.5–2 h |

**Estimated time:** 8–10 hours.

### Checklist

- [ ] I can create and delete the kind cluster, switch contexts, and set a default namespace.
- [ ] I can find any field with `kubectl explain` (e.g. `pod.spec.containers.readinessProbe`) without a browser.
- [ ] I can write a Pod manifest from memory with image, `command`/`args`, env, ports and resources.
- [ ] I can explain what `command` and `args` override in the image (ENTRYPOINT and CMD).
- [ ] I can generate a skeleton with `kubectl create ... --dry-run=client -o yaml` and clean it up.
- [ ] I can explain liveness vs readiness vs startup probes and what Kubernetes does when each one fails.
- [ ] I can predict a pod's QoS class (Guaranteed / Burstable / BestEffort) from its requests and limits.
- [ ] I can explain why exceeding a memory limit kills the container but exceeding a CPU limit only slows it down.
- [ ] I can add a native sidecar (`initContainers` + `restartPolicy: Always`) and explain how it differs from a normal init container.
- [ ] I can select objects with equality-based and set-based label selectors, and use `--field-selector`.
- [ ] I can explain why a pod without requests is rejected in a namespace with a CPU/memory ResourceQuota, and fix it with a LimitRange.
- [ ] I can follow the ownership chain Deployment → ReplicaSet → Pod through `ownerReferences`.
- [ ] I can perform a rolling update, watch it, pause and resume it, and **roll back a Deployment** to a specific revision.
- [ ] I can explain `maxSurge` / `maxUnavailable` and when to choose `Recreate`.
- [ ] I can expose a Deployment with ClusterIP and NodePort Services and reach it from inside and outside the cluster.
- [ ] I can explain how a Service finds its pods (selector → EndpointSlice) and why an unready pod gets no traffic.
- [ ] I can resolve `<svc>.<ns>.svc.cluster.local` from a pod and explain the search domains in its `/etc/resolv.conf`.
- [ ] I can consume a ConfigMap as env vars and as files, and say which of the two picks up changes without a restart.
- [ ] I can explain why base64 in a Secret is not encryption.

### Milestone 1: a two-tier app from scratch

Build it in a new namespace `lab-milestone1`. **Write every manifest
yourself**: generate skeletons, but don't copy from the modules. (Delete
module 04's namespace first if it still uses NodePort 30080.)

1. **api:** a Deployment with 2 replicas of `hashicorp/http-echo:1.0`
   listening on 5678. Its text should include the pod's name, using the
   Downward API plus `args: ["-text=hello from $(POD_NAME)", "-listen=:5678"]`.
   Put it behind a ClusterIP Service `api` on port 80.
2. **web:** a Deployment with 3 replicas of `nginx:1.27-alpine`. One
   ConfigMap provides `index.html`. Another provides a `default.conf` that
   serves the page and proxies `/api/` to `http://api/`. Expose it with a
   NodePort Service on `nodePort: 30080`. Hint: nginx looks up `api` when
   it starts. If that Service doesn't exist yet, nginx exits with
   `host not found in upstream`, so create the api first.
3. Store a fake API key in a Secret and mount it read-only at `/etc/api/key`
   in the api pods.
4. Every container gets requests, limits and a readiness probe. Add a
   ResourceQuota and a LimitRange to the namespace.

**Done when:**

* `curl localhost:30080` shows your page, and running
  `curl localhost:30080/api/` several times shows **different** pod names.
* You can change the page content, roll it out, see two revisions in
  `kubectl rollout history`, then `kubectl rollout undo` and see the old
  page again.
* You break it three ways and fix each one from the symptoms alone: a wrong
  Service selector, a wrong `targetPort`, a wrong readiness probe path.
  [troubleshooting.md](troubleshooting.md) is allowed; the solution in your
  own YAML isn't.

---

## Phase 2: Workloads and state

**Goal:** choose the right workload controller for a job, and understand
exactly how storage binds, where it lives, and what access modes really
guarantee.

| # | Module | Time |
|---|---|---|
| 06 | [Storage](../modules/06-storage/README.md) | 1.5 h |
| – | [Scenario: RWO PVC shared by two ordered pods](../scenarios/rwo-pvc-ordered-pods/README.md) | 1 h |
| 07 | [StatefulSets](../modules/07-statefulsets/README.md) | 1 h |
| 08 | [Jobs & CronJobs](../modules/08-jobs-cronjobs/README.md) | 1 h |
| 09 | [DaemonSets](../modules/09-daemonsets/README.md) | 45 min |
| | Milestone 2 | 1.5 h |

**Estimated time:** 6–8 hours.

### Checklist

- [ ] I can explain volume vs PersistentVolume vs PersistentVolumeClaim vs StorageClass, and who creates each one.
- [ ] I can explain why a PVC on kind's `standard` class stays `Pending` until a pod uses it (`WaitForFirstConsumer`).
- [ ] I can find which node a local-path PV lives on, and explain why a pod using it can only run there.
- [ ] **I can explain why RWO is per-node, not per-pod**, and show two pods on one node sharing an RWO volume.
- [ ] I can choose between RWO, ROX, RWX and RWOP for a given workload, and say what a cluster needs to offer RWX.
- [ ] I can say what happens to the data when a PVC is deleted under `Delete` vs `Retain`, and make a `Released` PV reusable.
- [ ] I can explain what the `Multi-Attach error` means and list three ways to avoid it.
- [ ] I can solve "one RWO volume, pod B must start after pod A" in at least two different ways and explain the trade-offs.
- [ ] I can run a StatefulSet and explain stable names, per-pod PVCs, ordered startup, and why it needs a headless Service.
- [ ] I can reach one specific StatefulSet pod by its DNS name.
- [ ] I can explain why scaling a StatefulSet down doesn't delete its PVCs by default, and what changes that.
- [ ] I can write a Job with `completions`, `parallelism` and `backoffLimit`, and an Indexed Job that uses its index.
- [ ] I can write a CronJob with `concurrencyPolicy` and history limits, and trigger it now with `kubectl create job --from=cronjob/<name>`.
- [ ] I can make finished Jobs clean themselves up with `ttlSecondsAfterFinished`.
- [ ] I can run a DaemonSet and explain why it does or doesn't land on the control-plane node.
- [ ] I can pick Deployment vs StatefulSet vs DaemonSet vs Job for a given description, and justify the choice.

### Milestone 2: a stateful counter

In namespace `lab-milestone2`, using `redis:7.4-alpine` for every container:

1. A Redis **StatefulSet** (1 replica, `--appendonly yes`) with a
   `volumeClaimTemplates` PVC and a headless Service `redis`.
2. A **CronJob**, every minute, running
   `redis-cli -h redis-0.redis INCR visits`. Set
   `concurrencyPolicy: Forbid` and history limits 3/1.
3. An **Indexed Job** (5 completions, parallelism 2). Each pod runs
   `SET item-$JOB_COMPLETION_INDEX <something>`.
4. A **DaemonSet** that, every 30 seconds, writes `node:<its node name>`
   with the current time into Redis. Get the node name from the Downward
   API (`spec.nodeName`).
5. A one-off **backup Job** that runs `redis-cli -h redis-0.redis --rdb /backup/dump.rdb`
   into its **own** PVC.

**Done when:**

* After `kubectl delete pod redis-0`, the `visits` counter keeps counting
  from where it was.
* After `kubectl delete sts redis` and re-applying it, all the data is
  still there, and you can explain why (the PVC was kept).
* You can name the node the Redis PV lives on and explain why `redis-0`
  always comes back to it.
* You can explain what `replicas: 2` would really give you: two
  *independent* Redis servers with separate data, not replication.

---

## Phase 3: Operating a cluster

**Goal:** control where things run, who may do what, how traffic enters
and moves inside the cluster, how workloads scale, and how to debug
anything quickly.

| # | Module | Time |
|---|---|---|
| 10 | [Scheduling](../modules/10-scheduling/README.md) | 1.5 h |
| 11 | [RBAC](../modules/11-rbac/README.md) | 1.5 h |
| 12 | [Ingress & Gateway API](../modules/12-ingress-gateway/README.md) | 1.5 h |
| 13 | [NetworkPolicies](../modules/13-network-policies/README.md) | 1 h |
| 14 | [Autoscaling](../modules/14-autoscaling/README.md) | 1 h |
| 15 | [Security](../modules/15-security/README.md) | 1.5 h |
| 16 | [Debugging](../modules/16-debugging/README.md) | 1.5 h |
| | Milestone 3 | 2 h |

**Estimated time:** 10–13 hours.

### Checklist

- [ ] I can pin pods with `nodeSelector` and node affinity, and spread replicas across `training/zone` with topology spread constraints.
- [ ] I can keep replicas apart with pod anti-affinity, and explain why "required" anti-affinity with more replicas than nodes leaves pods Pending.
- [ ] I can taint a node, explain `NoSchedule` vs `PreferNoSchedule` vs `NoExecute`, and write the matching toleration.
- [ ] I can explain that a toleration *allows* scheduling on a tainted node but doesn't *attract* the pod there.
- [ ] I can explain priority and preemption, and predict which pod gets preempted.
- [ ] I can create a ServiceAccount with a least-privilege Role and prove what it can and can't do with `kubectl auth can-i --as=system:serviceaccount:<ns>:<sa>`.
- [ ] I can read a `Forbidden` error and say exactly which verb, resource, API group and namespace are missing.
- [ ] I can tell an RBAC denial apart from a Pod Security or ResourceQuota rejection.
- [ ] I can explain the difference between an Ingress resource, an ingress controller and an IngressClass.
- [ ] I can route two hostnames or paths to two Services, with Ingress and with Gateway API (Gateway + HTTPRoute).
- [ ] I can explain what a 404 vs a 503 from the ingress controller tells me.
- [ ] I can write a default-deny NetworkPolicy, then allow only frontend → backend on one port, plus DNS egress.
- [ ] I can explain why NetworkPolicies are additive allow-lists, and why DNS breaks after a default-deny egress policy.
- [ ] I can install metrics-server, create an HPA, generate load, and watch it scale up and back down.
- [ ] I can explain why an HPA on CPU utilization needs CPU requests, and how `behavior` slows down scale-down.
- [ ] I can make a pod run as non-root with a read-only root filesystem and all capabilities dropped, and pass the `restricted` Pod Security Standard.
- [ ] I can label a namespace for Pod Security Admission (`enforce` / `warn` / `audit`) and preview the impact with `--dry-run=server`.
- [ ] I can debug a pod with `logs --previous`, events, `exec`, an ephemeral container (`kubectl debug --target`) and `--copy-to`.
- [ ] I can get a shell on a node with `kubectl debug node/...` (and with `docker exec` on kind).
- [ ] I can find the cause of Pending, ImagePullBackOff, CrashLoopBackOff, CreateContainerConfigError and OOMKilled in under 5 minutes each.
- [ ] I can drain a node safely and explain how a PodDisruptionBudget changes what drain does.

### Milestone 3: harden it, then break it

Copy your Milestone 1 app into `lab-milestone3` and make it
production-shaped:

1. Spread `web` across `training/zone` with topology spread constraints,
   and add a PodDisruptionBudget (`minAvailable: 2`).
2. Give each component its own ServiceAccount with
   `automountServiceAccountToken: false`. Add a `reader` ServiceAccount
   that can only `get`/`list` pods and read pod logs in this namespace,
   and prove it with `kubectl auth can-i --list`.
3. Expose the app at `http://web.localhost/` (page) and
   `http://web.localhost/api/` (API) through Ingress **or** Gateway API.
4. Add NetworkPolicies: default-deny ingress and egress, then allow the
   controller → web, web → api on 5678, and DNS.
5. Label the namespace `pod-security.kubernetes.io/enforce=restricted`
   and make every pod comply. nginx must run as non-root on a high port
   with writable `emptyDir`s; see [module 15](../modules/15-security/README.md).
6. Give the api an HPA (2–6 replicas, 50% CPU). Load it from a busybox or
   curl pod and watch it scale.

**Game day:** have a friend, or a list of numbered faults and a die, make
**five** changes from [troubleshooting.md](troubleshooting.md) without
telling you which. Examples: a wrong image tag, a missing ConfigMap key, a
selector typo, a NetworkPolicy without DNS, a memory limit that is too
low. **Done when** you've found and fixed all five using only kubectl, in
under 10 minutes each, and written down the symptom → cause → fix for
each.

---

## Phase 4: Packaging and real projects

**Goal:** stop applying loose YAML. Package an application so it can be
deployed repeatedly to different environments, then build a complete one.

| # | Module | Time |
|---|---|---|
| 17 | [Kustomize](../modules/17-kustomize/README.md) | 1.5 h |
| 18 | [Helm](../modules/18-helm/README.md) | 1.5 h |
| 19 | [Capstone](../modules/19-capstone/README.md) | 3–4 h |
| | Milestone 4 | 1–2 h |

**Estimated time:** 6–9 hours.

### Checklist

- [ ] I can organise manifests as a Kustomize base with `dev` and `prod` overlays (namespace, replicas, images, patches).
- [ ] I can use `configMapGenerator` and explain how the hash suffix triggers a rollout.
- [ ] I can preview changes before applying them with `kubectl kustomize` and `kubectl diff -k`.
- [ ] I can install, upgrade, roll back and uninstall a Helm release, overriding values with `-f` and `--set`.
- [ ] I can render a chart locally with `helm template` and validate the output with `kubectl apply --dry-run=server -f -`.
- [ ] I can write a small chart with templates, a `_helpers.tpl`, values and `helm lint`.
- [ ] I can explain when I'd choose Kustomize, Helm, or both.
- [ ] I can deploy a multi-tier app (web + API + database) with config, storage, ingress, autoscaling and network policies, starting from an empty cluster.
- [ ] I can tear the cluster down and rebuild the whole app from Git, without manual steps.

### Milestone 4: ship it

Package the [capstone](../modules/19-capstone/README.md) app two ways:

1. A Kustomize **base** plus **overlays**: `dev` (1 replica, small
   resources) and `prod` (3 replicas, HPA, PDB, stricter resources).
2. A **Helm chart** with sensible `values.yaml` defaults, a
   `values-prod.yaml`, and `helm lint` passing.

**Done when:** after `make cluster-down && make cluster-up` you can deploy
the full app with **one command per tool** in under 15 minutes. You can
then do a `helm upgrade` that changes something visible, and a
`helm rollback` that undoes it. Write the commands into a short README, as
if a colleague had to do it.

---

## Suggested schedule

About **6 weeks at ~1 hour a day, 5 days a week** (30 sessions). With
~1.5 hours a day, or extra weekend sessions, it fits into **4 weeks**. A
long module can take two sessions, and that's fine: understanding beats
speed.

| Week | Mon | Tue | Wed | Thu | Fri |
|---|---|---|---|---|---|
| 1 | 00 Setup | 01 Pods (containers, init, sidecars) | 01 Pods (probes, resources, QoS) | 02 Namespaces & labels | 03 Deployments |
| 2 | 03 exercises, 04 Services | 04 Services | 05 ConfigMaps & Secrets | Milestone 1 | Milestone 1 + review Phase 1 checklist |
| 3 | 06 Storage | 06 exercises | RWO scenario | 07 StatefulSets | 08 Jobs & CronJobs |
| 4 | 09 DaemonSets | Milestone 2 | 10 Scheduling | 11 RBAC | 12 Ingress & Gateway API |
| 5 | 13 NetworkPolicies | 14 Autoscaling | 15 Security | 16 Debugging | Milestone 3 (build) |
| 6 | Milestone 3 (game day) | 17 Kustomize | 18 Helm | 19 Capstone | 19 Capstone + Milestone 4 |

**4-week version:** fold each milestone into the weekend, and do two short
modules per session (02+03, 08+09, 13+14).

Every Friday, spend 10 minutes re-reading the checklists of the phases
you've finished, and redo any box you can't tick anymore. Spaced
repetition matters more than the extra hour.

## How to practise

* **Break things on purpose.** After every lab, change one thing and
  *predict* the result before you look: a selector typo, a wrong
  `targetPort`, a request bigger than a node, a missing ConfigMap key, a
  readiness probe on the wrong path, a NetworkPolicy without DNS. Then
  read the symptoms with `describe`, `events` and `logs`. Recognising
  symptoms is the skill that matters most in real work and in exams.
* **Re-type manifests instead of copying them.** Typing YAML builds the
  memory of field names and nesting that you'll need under time pressure.
  Generate skeletons with `kubectl create ... --dry-run=client -o yaml`
  and `kubectl run ... --dry-run=client -o yaml`, then add the rest by
  hand.
* **Use `kubectl explain` before a search engine.** `kubectl explain
  deploy.spec.strategy --recursive` is faster than a browser, always
  matches your cluster's version, and works offline.
* **Watch while you act.** Keep `kubectl get pods -w` or `kubectl events -w`
  running in a second terminal while you apply, scale, drain or delete.
  Seeing controllers react teaches more than reading about them.
* **Predict, then verify.** Before each command, say what you expect to
  happen ("2 old pods, 1 new pod, then…"). When you're wrong, you've found
  something worth learning.
* **Reset often.** `kubectl delete namespace lab-<topic>` and redo the lab
  from memory the next day. Recreate the whole cluster now and then
  (`make cluster-down && make cluster-up`). Being comfortable starting
  from zero is half of operating Kubernetes.
* **Keep an error journal.** Each time something breaks, write one line:
  *symptom → cause → fix → command that proved it*. After a few weeks it
  will be your personal [troubleshooting.md](troubleshooting.md).
* **Time yourself.** Once a phase feels easy, redo its exercises against a
  clock with only kubectl, `kubectl explain` and kubernetes.io, as in the
  exams. Use the [cheatsheet](kubectl-cheatsheet.md) until the commands
  are muscle memory, then stop using it.
* **Explain it out loud.** If you can't explain *why* (why RWO is
  per-node, why a pod is BestEffort, why a Service has no endpoints), you
  don't know it yet. The [glossary](glossary.md) has short, exact
  definitions to check yourself against.

## CKAD and CKA mapping

The CKAD (Certified Kubernetes Application Developer) and CKA (Certified
Kubernetes Administrator) are 2-hour, online, proctored, **hands-on**
exams: you solve tasks on real clusters from a terminal, and you may use
the kubernetes.io documentation. The domains and weights below are from
the CNCF's published curriculum
([github.com/cncf/curriculum](https://github.com/cncf/curriculum)),
checked in October 2026. The curriculum is revised from time to time, so
**check the current version before you book an exam**.

### Modules → exam domains

| Module | CKAD domains | CKA domains |
|---|---|---|
| 00 Setup | (tooling for every domain) | Cluster Architecture (components: an overview only) |
| 01 Pods | Design & Build (multi-container patterns, ephemeral volumes); Observability (probes); Environment, Config & Security (requests/limits) | Workloads & Scheduling (self-healing primitives); Troubleshooting (container output) |
| 02 Namespaces & labels | Environment, Config & Security (quotas) | Workloads & Scheduling (Pod admission: limits) |
| 03 Deployments | Deployment (rolling updates, deployment strategies); Design & Build (choosing a workload) | Workloads & Scheduling (rolling updates and rollbacks) |
| 04 Services | Services & Networking (access via Services) | Services & Networking (ClusterIP/NodePort/LoadBalancer, endpoints, CoreDNS, pod connectivity) |
| 05 ConfigMaps & Secrets | Environment, Config & Security (ConfigMaps, Secrets) | Workloads & Scheduling (ConfigMaps and Secrets) |
| 06 Storage + RWO scenario | Design & Build (persistent and ephemeral volumes) | Storage (all three competencies) |
| 07 StatefulSets | Design & Build (choosing a workload, persistent volumes) | Workloads & Scheduling; Storage (PVCs) |
| 08 Jobs & CronJobs | Design & Build (choosing a workload) | Workloads & Scheduling |
| 09 DaemonSets | Design & Build (choosing a workload) | Workloads & Scheduling |
| 10 Scheduling | (not a listed CKAD competency) | Workloads & Scheduling (Pod scheduling: node affinity etc.) |
| 11 RBAC | Environment, Config & Security (authn/authz, ServiceAccounts) | Cluster Architecture (RBAC) |
| 12 Ingress & Gateway API | Services & Networking (Ingress rules) | Services & Networking (Ingress controllers and resources, Gateway API) |
| 13 NetworkPolicies | Services & Networking (NetworkPolicies) | Services & Networking (NetworkPolicies) |
| 14 Autoscaling | Observability (CLI monitoring tools: `kubectl top`) | Workloads & Scheduling (workload autoscaling); Troubleshooting (resource usage) |
| 15 Security | Environment, Config & Security (SecurityContexts, capabilities, admission control) | Workloads & Scheduling (Pod admission) |
| 16 Debugging | Observability (logs, debugging) | Troubleshooting (applications, services, nodes) |
| 17 Kustomize | Deployment (Kustomize) | Cluster Architecture (Helm and Kustomize to install components) |
| 18 Helm | Deployment (Helm) | Cluster Architecture (Helm and Kustomize to install components) |
| 19 Capstone | All domains (integration practice) | All domains (integration practice) |

### Coverage by competency

**Yes** = taught with a lab. **Partly** = touched on, practise more on
your own. **No** = not in this course; study it elsewhere.

**CKAD**

| Domain (weight) | Competency | Coverage |
|---|---|---|
| Application Design and Build (20%) | Define, build and modify container images | **No.** Learn Dockerfiles and `docker build`/`podman build` separately; `kind load docker-image` gets your image into the cluster. |
| | Choose and use the right workload resource | Yes (03, 07, 08, 09) |
| | Multi-container Pod design patterns (sidecar, init, …) | Yes (01) |
| | Persistent and ephemeral volumes | Yes (01, 05, 06) |
| Application Deployment (20%) | Deployment strategies (e.g. blue/green, canary) with Kubernetes primitives | Partly (03, 04). Practise blue/green by switching a Service selector between two Deployments, and canary as two Deployments behind one Service. |
| | Deployments and rolling updates | Yes (03) |
| | Helm to deploy existing packages | Yes (18) |
| | Kustomize | Yes (17) |
| Application Observability and Maintenance (15%) | API deprecations | Partly (00: `kubectl api-versions`, `explain`; read the deprecation warnings kubectl prints). See the [Deprecated API Migration Guide](https://kubernetes.io/docs/reference/using-api/deprecation-guide/). |
| | Probes and health checks | Yes (01) |
| | Built-in CLI tools to monitor applications | Yes (14, 16) |
| | Container logs | Yes (16) |
| | Debugging in Kubernetes | Yes (16) |
| Application Environment, Configuration and Security (25%) | Resources that extend Kubernetes (CRD, Operators) | Partly (12 installs Gateway API CRDs). See [Where to go next](#where-to-go-next). |
| | Authentication, authorization and admission control | Yes (11, 15) |
| | Requests, limits, quotas; resource requirements | Yes (01, 02) |
| | ConfigMaps; Secrets | Yes (05) |
| | ServiceAccounts | Yes (11) |
| | Application security (SecurityContexts, capabilities) | Yes (15) |
| Services and Networking (20%) | NetworkPolicies (basic understanding) | Yes (13) |
| | Access to applications via Services (incl. troubleshooting) | Yes (04, 16) |
| | Ingress rules | Yes (12) |

**CKA**

| Domain (weight) | Competency | Coverage |
|---|---|---|
| Storage (10%) | StorageClasses and dynamic provisioning | Yes (06) |
| | Volume types, access modes, reclaim policies | Yes (06, RWO scenario) |
| | PersistentVolumes and PersistentVolumeClaims | Yes (06, 07) |
| Troubleshooting (30%) | Clusters and nodes | Partly (16; nodes via `kubectl debug node/` and `docker exec` on kind) |
| | Cluster components | Partly. Look at the static pods in `kube-system` and the kubelet logs on a kind node; real practice needs a kubeadm cluster. |
| | Monitor cluster and application resource usage | Yes (14) |
| | Container output streams | Yes (16) |
| | Services and networking | Yes (04, 13, 16) |
| Workloads and Scheduling (15%) | Deployments, rolling updates and rollbacks | Yes (03) |
| | ConfigMaps and Secrets | Yes (05) |
| | Workload autoscaling | Yes (14) |
| | Primitives for robust, self-healing deployments | Yes (01, 03, 07, 09) |
| | Pod admission and scheduling (limits, node affinity, …) | Yes (02, 10, 15) |
| Cluster Architecture, Installation and Configuration (25%) | RBAC | Yes (11) |
| | Prepare infrastructure for installing a cluster | **No** |
| | Create and manage clusters with kubeadm | **No.** kind uses kubeadm internally, but you never run it yourself. |
| | Manage the cluster lifecycle (e.g. upgrades) | **No** |
| | Highly-available control plane | **No** |
| | Helm and Kustomize to install cluster components | Yes (17, 18) |
| | Extension interfaces (CNI, CSI, CRI) | Partly (concepts in 06, 13 and the [glossary](glossary.md)) |
| | CRDs; install and configure operators | Partly (12). Install a real operator on your own, see [Where to go next](#where-to-go-next). |
| Services and Networking (20%) | Connectivity between Pods | Yes (04, 13) |
| | NetworkPolicies | Yes (13) |
| | ClusterIP, NodePort, LoadBalancer Services and endpoints | Yes, except LoadBalancer, which is concept only, since kind has no cloud LB (04) |
| | Gateway API for ingress traffic | Yes (12) |
| | Ingress controllers and Ingress resources | Yes (12) |
| | CoreDNS | Yes (04) |

**Closing the CKA gaps.** The cluster-administration competencies need
real VMs, not kind. Build a 1-control-plane, 1–2-worker cluster on local
VMs (Multipass, Vagrant or Lima) and work through the official tasks:
[Creating a cluster with kubeadm](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/),
[Upgrading kubeadm clusters](https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-upgrade/),
[Creating highly available clusters](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/high-availability/)
and [Operating etcd clusters](https://kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd/)
(including snapshot and restore). Do each one at least twice from scratch.
Exam registration has included access to an exam simulator, so use it
once you can tick every box above.

## Where to go next

* **Operators and CRDs.** Install a real operator and read its CRDs: e.g.
  [cert-manager](https://cert-manager.io/) (certificates for your
  Ingress/Gateway) or [CloudNativePG](https://cloudnative-pg.io/) (Postgres
  with failover and backups). Then write a small one yourself with
  [Kubebuilder](https://book.kubebuilder.io/) (controller-runtime) to see
  how reconciliation really works.
* **GitOps.** Keep your manifests (your Milestone 4 repo) in Git and let a
  controller apply them continuously:
  [Argo CD](https://argo-cd.readthedocs.io/) or [Flux](https://fluxcd.io/).
  Learn what drift detection, sync waves and image automation give you.
* **Service mesh.** mTLS between services, retries, traffic splitting and
  per-request telemetry without changing app code:
  [Istio](https://istio.io/) (including its sidecar-less *ambient* mode) or
  [Linkerd](https://linkerd.io/). Gateway API is increasingly the way both
  are configured.
* **Observability.** `kubectl top` only shows a snapshot. Install
  [Prometheus](https://prometheus.io/) and [Grafana](https://grafana.com/)
  (the `kube-prometheus-stack` Helm chart is the usual starting point),
  learn PromQL, write an alert on CPU throttling or restarts, and add logs
  (Loki) and traces ([OpenTelemetry](https://opentelemetry.io/)).
* **Managed Kubernetes in the cloud.** Repeat your capstone on EKS, GKE or
  AKS. What changes is real `LoadBalancer` Services, cloud CSI drivers
  (where you'll meet the [Multi-Attach error](troubleshooting.md#multi-attach-error-volume-is-already-exclusively-attached-to-one-node)
  for real), workload identity for cloud IAM, and node autoscaling (Cluster
  Autoscaler, Karpenter). Mind the bill: delete clusters when you're done.
* **Security, deeper.** Policy engines ([Kyverno](https://kyverno.io/),
  OPA Gatekeeper), image scanning and signing (Trivy, Sigstore cosign),
  runtime security (Falco), and the CKS certification after CKA.
* **Ingress, going forward.** Prefer the Gateway API for new work. The
  community ingress-nginx project announced its retirement in November
  2025, so check the status of whatever controller you choose.
* **Certifications.** KCNA (multiple choice, a good first step) → CKAD
  and/or CKA (this course) → CKS.
* **The hard way.** When you want to know what kind and kubeadm do for
  you, do [Kubernetes The Hard Way](https://github.com/kelseyhightower/kubernetes-the-hard-way)
  once.
