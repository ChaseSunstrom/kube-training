# kube-training

A hands-on, self-paced Kubernetes course you run on your own laptop.
Every lesson is a folder of real, commented manifests plus a README that walks
you through applying them, watching what happens, breaking things and fixing
them.

> **Looking for the "one ReadWriteOnce PVC shared by two pods, in a specific
> order" answer?** Go straight to
> [`scenarios/rwo-pvc-ordered-pods/`](scenarios/rwo-pvc-ordered-pods/README.md).
> It has four working patterns, a decision table and an automated test for
> each one.

---

## Quick start (10 minutes)

```bash
# 1. Install the tools (details: modules/00-setup)
#    docker (or podman), kubectl, kind      — helm/kustomize optional

# 2. Create the 3-node training cluster
make cluster-up            # = kind create cluster --config cluster/kind-multi-node.yaml

# 3. Check it works
kubectl get nodes          # 1 control-plane + 2 workers, all Ready

# 4. Start the first lesson
cat modules/01-pods/README.md
```

No `make`? Every target is a one-liner — see the [`Makefile`](Makefile).

## Learning path

Work through the modules in order. Each one builds on the previous ones, takes
roughly 30–90 minutes, and ends with exercises. The full roadmap with
checkboxes is in [`docs/learning-path.md`](docs/learning-path.md).

| # | Module | You will learn |
|---|---|---|
| 00 | [Setup](modules/00-setup/README.md) | Install tools, create a cluster, kubectl basics, contexts, `kubectl explain` |
| 01 | [Pods](modules/01-pods/README.md) | Pods, multi-container pods, init containers, sidecars, probes, resources, QoS |
| 02 | [Namespaces & labels](modules/02-namespaces-labels/README.md) | Namespaces, labels, selectors, annotations, ResourceQuota, LimitRange |
| 03 | [Deployments](modules/03-deployments/README.md) | ReplicaSets, scaling, rolling updates, rollbacks, Recreate strategy |
| 04 | [Services](modules/04-services/README.md) | ClusterIP, NodePort, headless, ExternalName, DNS, EndpointSlices |
| 05 | [ConfigMaps & Secrets](modules/05-config-secrets/README.md) | Env vars, mounted files, projected volumes, immutable config, updates |
| 06 | [Storage](modules/06-storage/README.md) | Volumes, PV/PVC, StorageClasses, access modes (RWO/ROX/RWX/RWOP), expansion |
| 07 | [StatefulSets](modules/07-statefulsets/README.md) | Stable identity, headless services, volumeClaimTemplates, ordered rollout |
| 08 | [Jobs & CronJobs](modules/08-jobs-cronjobs/README.md) | Completions, parallelism, retries, indexed jobs, schedules, TTL |
| 09 | [DaemonSets](modules/09-daemonsets/README.md) | Per-node agents, tolerations, update strategy |
| 10 | [Scheduling](modules/10-scheduling/README.md) | nodeSelector, (anti-)affinity, taints/tolerations, topology spread, priority |
| 11 | [RBAC](modules/11-rbac/README.md) | ServiceAccounts, Roles, ClusterRoles, bindings, `kubectl auth can-i` |
| 12 | [Ingress & Gateway API](modules/12-ingress-gateway/README.md) | Ingress, ingress controllers, Gateway API, host/path routing, TLS |
| 13 | [NetworkPolicies](modules/13-network-policies/README.md) | Default deny, allow-lists, namespace selectors, egress control |
| 14 | [Autoscaling](modules/14-autoscaling/README.md) | metrics-server, HPA, load testing, scaling behaviour |
| 15 | [Security](modules/15-security/README.md) | securityContext, Pod Security Admission, non-root, read-only FS, capabilities |
| 16 | [Debugging](modules/16-debugging/README.md) | Logs, events, exec, ephemeral containers, 8 broken apps to fix |
| 17 | [Kustomize](modules/17-kustomize/README.md) | Bases, overlays, patches, generators, image overrides |
| 18 | [Helm](modules/18-helm/README.md) | Charts, templates, values, releases, upgrades, rollbacks |
| 19 | [Capstone](modules/19-capstone/README.md) | Build a full app: web + API + database, config, storage, ingress, HPA, policies |

### Scenarios (real-world problems)

| Scenario | Problem |
|---|---|
| [RWO PVC shared by two ordered pods](scenarios/rwo-pvc-ordered-pods/README.md) | One `ReadWriteOnce` volume, two different pods, and pod B must only start after pod A — plus a Service in front. Four patterns: sequential hand-off, concurrent ordered start, StatefulSet ordering, and strict `ReadWriteOncePod` hand-off. |

## Reference docs

* [`docs/learning-path.md`](docs/learning-path.md) – roadmap with checklists and milestones (incl. CKAD/CKA mapping)
* [`docs/kubectl-cheatsheet.md`](docs/kubectl-cheatsheet.md) – the commands you'll use every day
* [`docs/troubleshooting.md`](docs/troubleshooting.md) – "my pod is X" → what to check
* [`docs/glossary.md`](docs/glossary.md) – every term used in this repo
* [`docs/CONVENTIONS.md`](docs/CONVENTIONS.md) – how modules are laid out (read before adding one)

## How every module works

* Each module owns **one namespace** (`lab-<topic>`), so labs never collide and
  cleanup is `kubectl delete namespace lab-<topic>`.
* Manifests are **numbered in apply order** and heavily commented — read the
  YAML, it is part of the lesson.
* `kubectl apply -f modules/NN-topic/` applies a whole module; the README walks
  you through it one file at a time so you can see each piece working.

## Repo tooling

```bash
make help            # list targets
make cluster-up      # create the kind cluster
make cluster-down    # delete it
make validate        # schema-check every manifest (kubeconform) — offline-friendly
make validate-server # server-side dry-run of every manifest against your cluster
make test-scenario   # run the RWO ordered-pods scenario end-to-end on your cluster
```

CI (`.github/workflows/validate.yaml`) runs the schema check on every push and
runs the RWO scenario tests on a real kind cluster.
