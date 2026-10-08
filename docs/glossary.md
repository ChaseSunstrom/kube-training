# Glossary

The terms used across this course, in alphabetical order. Each definition
is short and exact, and ends with a link to where the course teaches it.
"→ 06" means [module 06](../modules/06-storage/README.md).

[A](#a) · [B](#b) · [C](#c) · [D](#d) · [E](#e) · [F](#f) · [G](#g) · [H](#h) ·
[I](#i) · [J](#j) · [K](#k) · [L](#l) · [M](#m) · [N](#n) · [O](#o) · [P](#p) ·
[Q](#q) · [R](#r) · [S](#s) · [T](#t) · [U](#u) · [V](#v) · [W](#w)

---

## A

### Access modes
How a PersistentVolume may be mounted: [ReadWriteOnce](#readwriteonce-rwo),
[ReadOnlyMany](#readonlymany-rox), [ReadWriteMany](#readwritemany-rwx) and
[ReadWriteOncePod](#readwriteoncepod-rwop). Kubernetes uses them to match
PVCs to PVs and, for some volume types, to limit where a volume can be
mounted. They do **not** make a mounted volume read-only or write-protected.
→ [06](../modules/06-storage/README.md)

### Admission controller
Code in the API server that runs after authentication and authorization
and before an object is stored. *Mutating* admission can change the object;
*validating* admission can reject it. Built-in examples are `LimitRanger`,
`ResourceQuota`, `PodSecurity` and `DefaultStorageClass`. You can extend
admission with webhooks or a [ValidatingAdmissionPolicy](#validatingadmissionpolicy).
→ [15](../modules/15-security/README.md)

### Affinity and anti-affinity
Scheduling rules in `spec.affinity`. *Node affinity* attracts a pod to nodes
with certain labels. *Pod affinity* and *pod anti-affinity* place it near or
away from other pods within a `topologyKey` (a node, a zone). Rules are
either `requiredDuringSchedulingIgnoredDuringExecution` (hard) or
`preferredDuringScheduling…` (soft).
→ [10](../modules/10-scheduling/README.md)

### Annotation
Key/value metadata for tools and people. Annotations are not used for
selection, and the values can be large (256 KiB in total per object).
Examples: `kubernetes.io/change-cause`, `deployment.kubernetes.io/revision`.
→ [02](../modules/02-namespaces-labels/README.md)

### API group and version
Every kind belongs to an API group and version, written as
`apiVersion: <group>/<version>` (`apps/v1`, `networking.k8s.io/v1`), or just
`v1` for the core group. Versions mature from alpha to beta to GA (`v1`).
`kubectl api-resources` lists them all.
→ [00](../modules/00-setup/README.md)

### API server (kube-apiserver)
The front door of the control plane. It is a REST API that authenticates
and authorizes every request, runs admission, and is the only component
that reads and writes [etcd](#etcd). kubectl, the kubelet and every
controller talk to it, mostly by *watching* for changes.
→ [00](../modules/00-setup/README.md)

## B

### Base and overlay
Kustomize terms. A *base* is a directory of reusable manifests. An
*overlay* points at a base and adds the changes for one environment:
namespace, replicas, image tags, patches.
→ [17](../modules/17-kustomize/README.md)

### BestEffort, Burstable, Guaranteed
The three [QoS classes](#qos-class).

## C

### Capabilities (Linux)
Fine-grained pieces of root's power (`NET_BIND_SERVICE`, `SYS_ADMIN`,
`SYS_PTRACE`…), added or dropped per container in
`securityContext.capabilities`. The `restricted` Pod Security Standard
requires `drop: ["ALL"]`.
→ [15](../modules/15-security/README.md)

### Chart
A Helm package: a directory (or `.tgz`) with `Chart.yaml`, templates and a
default `values.yaml`. Installing a chart creates a [release](#release-helm).
→ [18](../modules/18-helm/README.md)

### cloud-controller-manager
An optional control-plane component that runs the cloud-specific
controllers. It creates load balancers for `type: LoadBalancer` Services,
sets node addresses and removes nodes that were deleted in the cloud. A
kind cluster doesn't have one.
→ [00](../modules/00-setup/README.md)

### Cluster
A set of [nodes](#node) that run containerized workloads, managed by a
[control plane](#control-plane). The course cluster is a kind cluster with
1 control-plane node and 2 worker nodes.
→ [00](../modules/00-setup/README.md)

### ClusterIP
The default [Service](#service) type: a stable virtual IP, reachable only
inside the cluster, that load-balances to the Service's ready endpoints.
→ [04](../modules/04-services/README.md)

### ClusterRole and ClusterRoleBinding
A ClusterRole is a cluster-wide set of [RBAC](#rbac-role-based-access-control)
rules. It can cover cluster-scoped resources (nodes, PVs) or be reused in
many namespaces. A ClusterRoleBinding grants it across the whole cluster; a
RoleBinding that references a ClusterRole grants it in one namespace only.
→ [11](../modules/11-rbac/README.md)

### CNI (Container Network Interface)
The plugin standard the container runtime calls to wire up each pod's
network: interface, IP address, routes. The plugin provides the flat pod
network and, if it supports it, enforces [NetworkPolicy](#networkpolicy).
kind uses kindnet; Calico and Cilium are common elsewhere.
→ [13](../modules/13-network-policies/README.md)

### ConfigMap
A namespaced object that holds non-confidential configuration as key/value
pairs (up to 1 MiB). Containers consume it as env vars, command arguments
or mounted files. Mounted files are updated in place after a short delay
(except `subPath` mounts); env vars only change when the container
restarts.
→ [05](../modules/05-config-secrets/README.md)

### Container
A process (or process tree) isolated with Linux namespaces and limited
with cgroups, started from an image. In Kubernetes, containers always run
inside a [pod](#pod).
→ [01](../modules/01-pods/README.md)

### Context
A named (cluster, user, namespace) triple in a [kubeconfig](#kubeconfig).
`kubectl config use-context` switches between them.
→ [00](../modules/00-setup/README.md)

### Control plane
The components that manage the cluster: [kube-apiserver](#api-server-kube-apiserver),
[etcd](#etcd), [kube-scheduler](#kube-scheduler),
[kube-controller-manager](#kube-controller-manager), plus the
[cloud-controller-manager](#cloud-controller-manager) in clouds. On kind
and kubeadm clusters they run as [static pods](#static-pod) on the
control-plane node (`kubectl get pods -n kube-system`).
→ [00](../modules/00-setup/README.md)

### Controller
A control loop that watches objects through the API server and acts to
make the actual state match the desired state (*reconciliation*). For
example, the Deployment controller creates and scales ReplicaSets. Most
built-in controllers run inside kube-controller-manager.
→ [03](../modules/03-deployments/README.md)

### CoreDNS
The cluster's DNS server: Deployment `coredns` and Service `kube-dns` in
`kube-system`. It answers `<svc>.<ns>.svc.cluster.local` with the Service's
ClusterIP, or with the pod IPs for a [headless Service](#headless-service).
→ [04](../modules/04-services/README.md)

### Cordon
Marks a node unschedulable (`spec.unschedulable: true`): new pods won't be
placed there, but running pods stay. `kubectl drain` cordons first, then
evicts.
→ [cheatsheet](kubectl-cheatsheet.md#19-labels-annotations-taints-cordon-drain)

### CrashLoopBackOff
A container waiting reason, not a pod phase. The container keeps exiting
and the kubelet restarts it with exponential back-off (10 s, doubling up to
5 min). The real cause is in `Last State` and in `kubectl logs --previous`.
→ [16](../modules/16-debugging/README.md), [troubleshooting](troubleshooting.md#crashloopbackoff)

### CRD (CustomResourceDefinition)
Adds a new resource type to the Kubernetes API (e.g. `HTTPRoute`). The API
server stores and serves the new objects like built-in ones, but nothing
*happens* until a controller acts on them.
→ [12](../modules/12-ingress-gateway/README.md) (Gateway API is installed as CRDs)

### CRI (Container Runtime Interface)
The gRPC API the kubelet uses to run containers through a runtime such as
containerd (used by kind) or CRI-O. `crictl` is its command-line client.
History: Docker Engine was supported through *dockershim*, which was
removed in v1.24.
→ [00](../modules/00-setup/README.md)

### CronJob
Creates [Jobs](#job) on a cron schedule (`spec.schedule`, with an optional
`timeZone`). `concurrencyPolicy` (`Allow`/`Forbid`/`Replace`) decides what
happens when a run is still going, and history limits decide how many
finished Jobs are kept.
→ [08](../modules/08-jobs-cronjobs/README.md)

### CSI (Container Storage Interface)
The standard API that storage vendors implement as drivers. A driver is a
controller plus a plugin on every node, and it provisions, attaches and
mounts volumes. CSI replaced the in-tree cloud volume plugins. kind's
local-path provisioner is *not* a CSI driver (`kubectl get csidrivers` is
empty on the course cluster).
→ [06](../modules/06-storage/README.md)

## D

### DaemonSet
Runs one copy of a pod on every eligible node, and adds a pod when a node
joins. "Eligible" depends on node selectors and on tolerations for the
node's taints. Used for node agents: CNI, kube-proxy, log shippers.
→ [09](../modules/09-daemonsets/README.md)

### Declarative configuration
You describe the desired state in manifests and let controllers converge
on it (`kubectl apply`), instead of issuing step-by-step commands
(`kubectl run`, `kubectl scale`).
→ [00](../modules/00-setup/README.md)

### Deployment
Manages stateless, replicated pods through [ReplicaSets](#replicaset), and
provides rolling updates, rollbacks, scaling and pause/resume. Each change
to the pod template creates a new ReplicaSet, i.e. a new *revision*.
→ [03](../modules/03-deployments/README.md)

### Downward API
Gives containers facts about their own pod (name, namespace, IP, node,
labels, annotations, resource requests and limits) as env vars
(`fieldRef`, `resourceFieldRef`) or as files.
→ [01](../modules/01-pods/README.md)

### Drain
`kubectl drain <node>` cordons a node and evicts its pods through the
Eviction API, respecting [PodDisruptionBudgets](#poddisruptionbudget-pdb).
It is the normal first step before node maintenance.
→ [cheatsheet](kubectl-cheatsheet.md#19-labels-annotations-taints-cordon-drain)

## E

### emptyDir
A scratch volume that is created empty when a pod starts on a node and
deleted when the pod leaves that node. It survives container restarts.
`medium: Memory` puts it in RAM (tmpfs) and counts against the memory
limit.
→ [06](../modules/06-storage/README.md)

### EndpointSlice
`discovery.k8s.io/v1` objects that list the addresses, ports and
conditions (`ready`, `serving`, `terminating`) of a Service's backends. The
EndpointSlice controller keeps them up to date from the Service's selector,
and they carry the label `kubernetes.io/service-name`. They replace the
v1 `Endpoints` API, which is deprecated as of v1.33.
→ [04](../modules/04-services/README.md)

### Ephemeral container
A temporary container added to a *running* pod with `kubectl debug`, for
troubleshooting. It has no ports, probes or resource guarantees, cannot be
removed or restarted, and goes away with the pod.
→ [16](../modules/16-debugging/README.md)

### etcd
The consistent, distributed key-value store that holds all cluster state.
Only the API server talks to it. Backing up etcd backs up every object in
the cluster.
→ [00](../modules/00-setup/README.md)

### Eviction
Removing a pod from its node. In a *node-pressure eviction*, the kubelet
kills pods because memory, disk or PIDs are running low; those pods end up
`Failed` with reason `Evicted`. An *API-initiated eviction* is a request to
the Eviction API (as `kubectl drain` makes), and it respects
PodDisruptionBudgets.
→ [troubleshooting](troubleshooting.md#evicted)

### Event
A short-lived object (`kubectl events`) that records something that
happened to another object: a scheduling decision, an image pull, a probe
failure, a mount error. Kept for about 1 hour by default.
→ [16](../modules/16-debugging/README.md)

### ExternalName
A [Service](#service) type with no selector and no proxying: cluster DNS
answers with a CNAME to `spec.externalName` (e.g. `db.example.com`).
→ [04](../modules/04-services/README.md)

## F

### Field selector
A server-side filter on certain object fields, e.g.
`--field-selector status.phase=Running,spec.nodeName=kube-training-worker`.
Each kind supports only a few fields.
→ [cheatsheet](kubectl-cheatsheet.md#5-selectors-labels-and-fields)

### Finalizer
A key in `metadata.finalizers` that blocks deletion. Deleting the object
only sets `deletionTimestamp`; the object is removed once every finalizer
has been cleared, normally by the controller that added it. Examples:
`kubernetes.io/pvc-protection`, `kubernetes.io/pv-protection`,
`foregroundDeletion`.
→ [06](../modules/06-storage/README.md), [troubleshooting](troubleshooting.md#terminating-forever)

## G

### Garbage collection (cascading deletion)
The garbage collector deletes objects whose owners, listed in their
[ownerReferences](#ownerreferences), no longer exist. That is why deleting a
Deployment also deletes its ReplicaSets and pods. You choose the mode with
`kubectl delete --cascade=background` (the default), `foreground` (the
owner waits for its dependents) or `orphan` (the dependents are kept).
→ [03](../modules/03-deployments/README.md)

### Gateway API
The successor to Ingress (`gateway.networking.k8s.io/v1`), installed as
[CRDs](#crd-customresourcedefinition). A *GatewayClass* names the
controller. A *Gateway* defines listeners (ports, hostnames, TLS). *Routes*
(HTTPRoute, GRPCRoute…) attach to a Gateway and send traffic to Services.
It is role-oriented, supports header matching and weighted traffic
splitting, and allows cross-namespace references through a
*ReferenceGrant*.
→ [12](../modules/12-ingress-gateway/README.md)

### Generator (Kustomize)
`configMapGenerator` and `secretGenerator` build ConfigMaps and Secrets
from files or literals and add a hash of the content to the name. Changing
the content changes the name, and so triggers a rollout of every
Deployment that uses it.
→ [17](../modules/17-kustomize/README.md)

## H

### Headless Service
A Service with `clusterIP: None`. There is no virtual IP and no load
balancing: DNS returns the ready pod IPs directly. StatefulSet pods also
get per-pod names such as `redis-0.redis.<ns>.svc.cluster.local`.
→ [04](../modules/04-services/README.md), [07](../modules/07-statefulsets/README.md)

### Helm
A package manager for Kubernetes. It renders [chart](#chart) templates with
*values* and installs the result as a [release](#release-helm), so you can
`helm upgrade`, `helm rollback` and `helm uninstall` it later.
→ [18](../modules/18-helm/README.md)

### HorizontalPodAutoscaler (HPA)
An `autoscaling/v2` controller that sets a workload's `replicas` from
metrics, between `minReplicas` and `maxReplicas`, with optional `behavior`
rules that limit how fast it scales. The metrics are CPU or memory
*utilization relative to requests* (from metrics-server) or custom and
external metrics.
→ [14](../modules/14-autoscaling/README.md)

### hostPath
A volume that mounts a file or directory from the node's own filesystem.
The data is tied to that node, and access to the host is a security risk:
the `baseline` Pod Security Standard forbids hostPath volumes.
→ [06](../modules/06-storage/README.md)

## I

### Image pull policy
`imagePullPolicy` takes `IfNotPresent`, `Always` or `Never`. `Always` asks
the registry on every container start, and reuses the cached layers if the
digest hasn't changed. The default is `Always` when the tag is `:latest` or
missing, and `IfNotPresent` otherwise.
→ [01](../modules/01-pods/README.md)

### imagePullSecrets
References to `kubernetes.io/dockerconfigjson` Secrets that hold registry
credentials. You set them on the pod, or on its ServiceAccount (every pod
using that ServiceAccount inherits them). Create one with
`kubectl create secret docker-registry`.
→ [troubleshooting](troubleshooting.md#imagepullbackoff--errimagepull)

### Immutable ConfigMap / Secret
`immutable: true` forbids any change to the data. To change it you delete
and recreate the object. This protects against accidental edits and saves
the API server from kubelet watches.
→ [05](../modules/05-config-secrets/README.md)

### Ingress
A `networking.k8s.io/v1` object with host- and path-based HTTP(S) routing
rules to Services, plus TLS settings. It does nothing without an
[ingress controller](#ingress-controller-and-ingressclass).
→ [12](../modules/12-ingress-gateway/README.md)

### Ingress controller and IngressClass
An ingress controller (e.g. ingress-nginx, Traefik) is a proxy running in
the cluster that watches Ingress objects and implements them. An
IngressClass names a controller. An Ingress chooses one with
`spec.ingressClassName`, or falls back to the class marked as default.
→ [12](../modules/12-ingress-gateway/README.md)

### Init container
A container that runs to completion before the app containers start. Init
containers run one at a time, in order. A failing one is retried according
to the pod's `restartPolicy`. Use them for setup: waiting for a dependency,
fetching config, fixing permissions.
→ [01](../modules/01-pods/README.md)

## J

### Job
Runs pods until enough of them succeed (`completions`, `parallelism`),
retrying failures up to `backoffLimit` (default 6). `completionMode:
Indexed` gives each pod its own index, and `ttlSecondsAfterFinished`
deletes the Job automatically when it finishes.
→ [08](../modules/08-jobs-cronjobs/README.md)

### JSONPath
The query language behind `kubectl get -o jsonpath=…` and
`kubectl wait --for=jsonpath=…`, e.g. `{.items[*].metadata.name}`, with
filters (`[?(@.type=="Ready")]`) and `range`.
→ [cheatsheet](kubectl-cheatsheet.md#4-output-formats-jsonpath-custom-columns-sorting)

## K

### kind (Kubernetes IN Docker)
A tool that runs each Kubernetes node as a Docker (or Podman) container.
The course cluster is created from `cluster/kind-multi-node.yaml`. The
nodes run containerd, so images you build locally must be copied in with
`kind load docker-image`.
→ [00](../modules/00-setup/README.md)

### kube-controller-manager
The control-plane binary that runs the built-in [controllers](#controller):
Deployment, ReplicaSet, StatefulSet, Job, CronJob, node lifecycle,
EndpointSlice, PV binding, attach/detach, namespace, garbage collection and
more.
→ [00](../modules/00-setup/README.md)

### kube-proxy
A per-node agent (a DaemonSet) that programs packet-forwarding rules so
traffic to a Service's ClusterIP or NodePort reaches one of its ready
endpoints. It uses iptables on kind; IPVS and nftables modes also exist.
Some CNIs (e.g. Cilium) can replace it.
→ [04](../modules/04-services/README.md)

### kube-scheduler
The control-plane component that picks a node for every unscheduled pod. It
*filters* out nodes that can't run the pod (resources, selectors, taints,
volumes), *scores* the rest, and *binds* the pod by setting
`spec.nodeName`.
→ [10](../modules/10-scheduling/README.md)

### kubeconfig
The YAML file that lists clusters, users (credentials) and
[contexts](#context) for kubectl and other clients. It lives at
`~/.kube/config` by default; override it with `$KUBECONFIG` or
`--kubeconfig`.
→ [00](../modules/00-setup/README.md)

### kubectl
The Kubernetes command-line client. Every kubectl command is an HTTP call
to the API server, and `-v=6` shows you those calls.
→ [00](../modules/00-setup/README.md), [cheatsheet](kubectl-cheatsheet.md)

### kubelet
The agent on every node. It registers the node, runs the pods assigned to
it through the [CRI](#cri-container-runtime-interface), mounts volumes,
runs probes, reports status, and evicts pods under resource pressure. It
runs as a systemd service, not as a pod.
→ [00](../modules/00-setup/README.md)

### Kustomize
Template-free customization of YAML, built into kubectl (`kubectl apply -k`,
`kubectl kustomize`). A `kustomization.yaml` lists resources and applies
namespaces, name prefixes, labels, images, replicas, patches and
[generators](#generator-kustomize).
→ [17](../modules/17-kustomize/README.md)

## L

### Label
An identifying key/value pair on any object (`app: web`). [Label
selectors](#label-selector) use labels to group objects: Services find
their pods this way, Deployments recognise their pods this way, and so does
`kubectl get -l`.
→ [02](../modules/02-namespaces-labels/README.md)

### Label selector
A query over labels. It is either equality-based (`app=web`, `tier!=db`) or
set-based (`env in (dev,qa)`, `!canary`). In YAML it is written as
`matchLabels` and `matchExpressions`. A Deployment's `spec.selector` cannot
be changed after creation.
→ [02](../modules/02-namespaces-labels/README.md)

### LimitRange
A namespaced policy that gives default requests and limits to containers
that don't set any, and enforces minimum and maximum values per container,
pod or PVC.
→ [02](../modules/02-namespaces-labels/README.md)

### Liveness probe
A periodic health check. After `failureThreshold` failures in a row, the
kubelet **restarts the container**. Use it to recover from deadlocks, never
to check dependencies such as a database.
→ [01](../modules/01-pods/README.md)

### LoadBalancer
A Service type that also asks the cloud (through the
cloud-controller-manager) or a load-balancer implementation such as
MetalLB or cloud-provider-kind for an external IP. It includes a NodePort
and a ClusterIP. On a plain kind cluster the `EXTERNAL-IP` stays
`<pending>`.
→ [04](../modules/04-services/README.md)

## M

### Manifest
A YAML (or JSON) file that describes one or more Kubernetes objects with
`apiVersion`, `kind`, `metadata` and `spec`. You apply it with
`kubectl apply -f`.
→ [00](../modules/00-setup/README.md)

### metrics-server
A cluster add-on that collects CPU and memory usage from every kubelet and
serves the `metrics.k8s.io` API, which `kubectl top` and the HPA use. It
keeps no history, so it is not a monitoring system.
→ [14](../modules/14-autoscaling/README.md)

### Multi-Attach error
`Multi-Attach error for volume … Volume is already exclusively attached to
one node`: an attachable ReadWriteOnce volume is needed on a second node
while it is still attached to the first.
→ [troubleshooting](troubleshooting.md#multi-attach-error-volume-is-already-exclusively-attached-to-one-node),
[scenario](../scenarios/rwo-pvc-ordered-pods/README.md)

## N

### Namespace
A scope for object names and for policies (RBAC, ResourceQuota,
LimitRange, NetworkPolicy, Pod Security labels). A namespace is **not** a
network or security boundary by itself. Some resources are cluster-scoped
and belong to no namespace: nodes, PVs, StorageClasses, ClusterRoles,
namespaces themselves.
→ [02](../modules/02-namespaces-labels/README.md)

### NetworkPolicy
Namespaced allow-list rules for pod traffic in either direction (ingress,
egress). Peers are chosen by pod labels, namespace labels or IP blocks. A
pod is unrestricted until some policy selects it for a direction. Policies
only add allowances (there are no deny rules), and they work only if the
CNI enforces them.
→ [13](../modules/13-network-policies/README.md)

### Node
A machine that runs pods: a VM, a physical server or, on kind, a container.
It runs the kubelet, a container runtime and usually kube-proxy. The Node
object is cluster-scoped and carries labels, taints, capacity/allocatable
resources and conditions (`Ready`, `MemoryPressure`, `DiskPressure`,
`PIDPressure`).
→ [00](../modules/00-setup/README.md), [10](../modules/10-scheduling/README.md)

### nodeName
`spec.nodeName` is the node a pod is bound to, normally set by the
scheduler. If you set it yourself, the pod skips the scheduler entirely:
nothing filters the node and `NoSchedule` taints are ignored. The kubelet
may still reject the pod if it doesn't fit.
→ [10](../modules/10-scheduling/README.md)

### NodePort
A Service type that opens the same port (default range 30000–32767) on
every node and forwards it to the Service. It includes a ClusterIP. On the
course cluster, port 30080 on the control-plane node is mapped to
`localhost:30080`.
→ [04](../modules/04-services/README.md)

## O

### OOMKilled
The termination reason when the kernel's OOM killer stops a container,
because it went over its memory limit or because the node ran out of
memory. The exit code is 137.
→ [01](../modules/01-pods/README.md), [troubleshooting](troubleshooting.md#oomkilled)

### Operator
A pattern rather than an object: a custom [controller](#controller) plus
[CRDs](#crd-customresourcedefinition) that encode how to run one specific
application (install, upgrade, back up, fail over), e.g. a PostgreSQL
operator.
→ [learning path](learning-path.md#where-to-go-next)

### ownerReferences
`metadata.ownerReferences` lists the objects that own this one: a Pod is
owned by its ReplicaSet, which is owned by its Deployment. `controller:
true` marks the managing controller. The [garbage
collector](#garbage-collection-cascading-deletion) uses these references
for cascading deletion, and controllers use them to adopt and release
objects.
→ [03](../modules/03-deployments/README.md)

## P

### Patch types
`kubectl patch` updates part of an object, in one of three ways:

* **Strategic merge patch**, the default for built-in kinds, merges lists
  by a key (e.g. containers by `name`).
* **JSON merge patch** (RFC 7386, `--type=merge`) replaces whole lists, and
  a `null` value deletes a key.
* **JSON patch** (RFC 6902, `--type=json`) applies explicit
  `add`/`remove`/`replace` operations at JSON-pointer paths.

Custom resources don't support strategic merge.
→ [cheatsheet](kubectl-cheatsheet.md#8-edit-and-patch)

### PersistentVolume (PV)
A cluster-scoped piece of storage with a capacity, access modes, a
[reclaim policy](#reclaim-policy) and often node affinity. An admin creates
it (*static*), or a provisioner creates it for a PVC (*dynamic*). Phases:
`Available`, `Bound`, `Released`, `Failed`.
→ [06](../modules/06-storage/README.md)

### PersistentVolumeClaim (PVC)
A namespaced request for storage (size, access modes, StorageClass) that
binds one-to-one to a PV. Pods mount the claim, never the PV directly.
→ [06](../modules/06-storage/README.md)

### Pod
The smallest deployable unit: one or more containers that are scheduled
together onto one node and share a network namespace (one IP address, one
port space, `localhost`) and volumes. Pods are disposable: controllers
replace them with new ones that have new names and IPs.
→ [01](../modules/01-pods/README.md)

### Pod phase and conditions
`status.phase` is one of `Pending`, `Running`, `Succeeded`, `Failed` or
`Unknown`. `status.conditions` add detail: `PodScheduled`,
`PodReadyToStartContainers`, `Initialized`, `ContainersReady`, `Ready` and
sometimes `DisruptionTarget`. The STATUS column of `kubectl get pods` is
computed from these and from the container states, and is not the phase.
→ [01](../modules/01-pods/README.md)

### PodDisruptionBudget (PDB)
A `policy/v1` object that limits *voluntary* disruptions. Given a label
selector and either `minAvailable` or `maxUnavailable`, the Eviction API
(and so `kubectl drain`) refuses evictions that would break the budget. It
does not protect against node crashes or plain `kubectl delete pod`.
→ [cheatsheet](kubectl-cheatsheet.md#19-labels-annotations-taints-cordon-drain)

### Pod Security Admission (PSA)
The built-in admission controller that enforces the *Pod Security
Standards* (`privileged`, `baseline`, `restricted`) per namespace. You set
them with the labels `pod-security.kubernetes.io/enforce`, `audit` and
`warn`. History: PSA replaced PodSecurityPolicy, which was removed in
v1.25.
→ [15](../modules/15-security/README.md)

### PriorityClass and preemption
A cluster-scoped PriorityClass maps a name to an integer priority. Pods
that set `priorityClassName` are scheduled in priority order, and when one
doesn't fit, the scheduler may *preempt* (evict) lower-priority pods to make
room. Built-in classes: `system-cluster-critical`, `system-node-critical`.
→ [10](../modules/10-scheduling/README.md)

### Probe
A check the kubelet runs against a container, of type `httpGet`,
`tcpSocket`, `grpc` or `exec`. You tune it with `initialDelaySeconds`,
`periodSeconds`, `timeoutSeconds` (default 1) and `failureThreshold`. There
are three kinds: [liveness](#liveness-probe), [readiness](#readiness-probe)
and [startup](#startup-probe).
→ [01](../modules/01-pods/README.md)

### Projected volume
A single volume that merges several sources (Secrets, ConfigMaps, Downward
API fields, ServiceAccount tokens) into one directory. ServiceAccount
tokens are mounted this way, as the `kube-api-access-*` volume.
→ [05](../modules/05-config-secrets/README.md)

## Q

### QoS class
Every pod gets a QoS class from its resource settings:

* **Guaranteed**: every container has CPU and memory requests equal to its
  limits.
* **Burstable**: at least one container has a CPU or memory request or
  limit, but the pod isn't Guaranteed.
* **BestEffort**: no requests or limits at all.

The class affects eviction under node pressure and the kernel's OOM-kill
order: BestEffort goes first, Guaranteed last.
→ [01](../modules/01-pods/README.md)

## R

### RBAC (Role-Based Access Control)
The authorizer that decides whether a subject (user, group, ServiceAccount)
may perform a verb on a resource. It uses Roles and ClusterRoles, which
only contain allow rules (apiGroups, resources, verbs), plus bindings.
There are no deny rules.
→ [11](../modules/11-rbac/README.md)

### ReadOnlyMany (ROX)
An access mode: many nodes can mount the volume read-only.
→ [06](../modules/06-storage/README.md)

### ReadWriteMany (RWX)
An access mode: many nodes can mount the volume read-write at the same
time. It needs shared or file storage (NFS, CephFS, cloud file services).
kind's local-path provisioner doesn't support it.
→ [06](../modules/06-storage/README.md)

### ReadWriteOnce (RWO)
An access mode: the volume can be mounted read-write by **a single node**
at a time, and any number of pods **on that node** can use it together. A
pod on another node fails to attach ([Multi-Attach
error](#multi-attach-error)) or, for node-local volumes, is never scheduled
there.
→ [06](../modules/06-storage/README.md), [scenario](../scenarios/rwo-pvc-ordered-pods/README.md)

### ReadWriteOncePod (RWOP)
An access mode: the volume can be used by **a single pod** in the whole
cluster, and a second pod that uses the claim stays `Pending`. GA since
v1.29. The docs say only CSI volumes support it, but kind's local-path
provisioner also accepts it, and the scheduler enforces it.
→ [06](../modules/06-storage/README.md), [scenario](../scenarios/rwo-pvc-ordered-pods/README.md)

### Readiness probe
A periodic check of whether a container can serve traffic. While it fails,
the pod is not `Ready` and is marked not-ready in its Services'
EndpointSlices, so it gets no traffic. The container is **not** restarted.
→ [01](../modules/01-pods/README.md)

### Reclaim policy
`persistentVolumeReclaimPolicy` decides what happens to a PV when its claim
is deleted. **Delete** removes the PV and its backing storage; it is the
default for dynamically provisioned volumes. **Retain** keeps the PV, now
`Released`, with its data for manual recovery. (`Recycle` is deprecated.)
→ [06](../modules/06-storage/README.md)

### Release (Helm)
One installed instance of a chart, with a name and a numbered revision
history. Helm stores the revisions as Secrets in the release's namespace by
default.
→ [18](../modules/18-helm/README.md)

### ReplicaSet
Keeps a given number of identical pods running, matched by a label
selector. You rarely create one yourself: a Deployment creates one per
pod-template revision.
→ [03](../modules/03-deployments/README.md)

### Requests and limits
The per-container `resources` settings. **Requests** are what the
scheduler reserves on a node, and they are the base for HPA utilization.
**Limits** cap usage: a container over its CPU limit is throttled, one over
its memory limit is OOM-killed.
→ [01](../modules/01-pods/README.md)

### ResourceQuota
A namespaced object that caps aggregate usage: total CPU and memory
requests and limits, storage, and object counts (pods, Services, PVCs…).
Once a quota covers CPU or memory, every new pod must set those values
(or get defaults from a [LimitRange](#limitrange)), or it is rejected.
→ [02](../modules/02-namespaces-labels/README.md)

### restartPolicy
A pod-level setting, `Always` (default), `OnFailure` or `Never`, that
applies to all containers. Job pods must use `OnFailure` or `Never`. On an
init container, `restartPolicy: Always` turns it into a [sidecar](#sidecar-container).
→ [01](../modules/01-pods/README.md)

### Role and RoleBinding
A Role is a namespaced set of RBAC rules. A RoleBinding grants a Role (or a
ClusterRole) to users, groups or ServiceAccounts, but only within its own
namespace.
→ [11](../modules/11-rbac/README.md)

### Rolling update
The default Deployment strategy: pods of the new ReplicaSet are added and
old ones removed gradually. `maxSurge` (default 25%) is how many extra
pods may exist during the update, and `maxUnavailable` (default 25%) how
many may be missing. The alternative, `Recreate`, stops all old pods
before starting new ones.
→ [03](../modules/03-deployments/README.md)

### Rollback
`kubectl rollout undo` re-applies the pod template of an earlier revision.
Revisions are kept as old ReplicaSets (`revisionHistoryLimit`, default
10), and the rollback itself becomes a new revision number.
→ [03](../modules/03-deployments/README.md)

## S

### Scheduling gates
While `spec.schedulingGates` lists any gate, the pod stays unscheduled
(STATUS `SchedulingGated`). The scheduler considers it only after every gate
has been removed, which is usually done by an external controller.
→ [10](../modules/10-scheduling/README.md)

### Secret
A namespaced object for confidential data (passwords, tokens, TLS keys),
consumed like a ConfigMap. The values are only **base64-encoded**, which
is not encryption. The protection comes from RBAC, from encryption at rest
(if the cluster has it configured) and from keeping Secrets out of Git.
Types include `Opaque`, `kubernetes.io/tls` and
`kubernetes.io/dockerconfigjson`.
→ [05](../modules/05-config-secrets/README.md)

### securityContext
Security settings at pod and container level: `runAsUser`/`runAsGroup`,
`runAsNonRoot`, `fsGroup`, `readOnlyRootFilesystem`,
`allowPrivilegeEscalation`, `capabilities`, `privileged`,
`seccompProfile`.
→ [15](../modules/15-security/README.md)

### Server-side apply
`kubectl apply --server-side` makes the API server do the merge and
record which manager owns each field (`metadata.managedFields`). If you
would overwrite a field another manager owns, you get a conflict.
→ [cheatsheet](kubectl-cheatsheet.md#6-create-apply-diff-replace-delete)

### Service
A stable name and virtual IP in front of a set of pods chosen by a label
selector, mapping `port` to `targetPort`. The types are `ClusterIP`,
`NodePort`, `LoadBalancer` and `ExternalName`, and a
[headless](#headless-service) Service has no virtual IP at all.
→ [04](../modules/04-services/README.md)

### ServiceAccount
A namespaced identity for processes running in pods, seen by the API server
as `system:serviceaccount:<ns>:<name>`. Pods get a short-lived,
automatically rotated token through a projected volume; turn that off with
`automountServiceAccountToken: false`. `kubectl create token` issues a
token by hand.
→ [11](../modules/11-rbac/README.md)

### Sidecar container
A helper container (a proxy, a log shipper) that runs next to the main app
for the pod's whole life. A *native* sidecar is an init container with
`restartPolicy: Always`. It starts before the app containers and keeps
running, it doesn't keep a Job from completing, and it is stopped after
the app containers. GA in v1.33.
→ [01](../modules/01-pods/README.md)

### Startup probe
Runs first. Liveness and readiness probes are paused until it succeeds,
and if it fails `failureThreshold` times the container is restarted. It
gives slow starters time without weakening the liveness probe.
→ [01](../modules/01-pods/README.md)

### StatefulSet
Manages pods with stable identities. They get ordinal names (`web-0`,
`web-1`), their own PVCs from [volumeClaimTemplates](#volumeclaimtemplates)
and stable DNS names through a headless Service. By default they are
created, scaled and updated in order.
→ [07](../modules/07-statefulsets/README.md)

### Static pod
A pod that the kubelet runs straight from a manifest file on the node (e.g.
`/etc/kubernetes/manifests`). The API shows a read-only *mirror pod* for it.
kubeadm and kind run the control plane this way.
→ [00](../modules/00-setup/README.md)

### StorageClass
A cluster-scoped description of a kind of storage: `provisioner`,
`parameters`, `reclaimPolicy`, `volumeBindingMode` and
`allowVolumeExpansion`. A PVC that names it gets a dynamically provisioned
PV, and one class can be marked as the default. On kind the default is
`standard` (rancher local-path).
→ [06](../modules/06-storage/README.md)

## T

### Taint and toleration
A taint on a node (`key=value:effect`) keeps away pods that don't tolerate
it. The effect is `NoSchedule` (don't place new pods), `PreferNoSchedule`
(avoid if possible) or `NoExecute` (also evict running pods, after
`tolerationSeconds` if set). A toleration in the pod spec *allows* the pod
on such a node; it doesn't *send* it there.
→ [10](../modules/10-scheduling/README.md)

### terminationGracePeriodSeconds
How long the kubelet waits after running the `preStop` hook (if any) and
sending SIGTERM before it sends SIGKILL. Default: 30 seconds.
→ [01](../modules/01-pods/README.md)

### Topology spread constraints
`spec.topologySpreadConstraints` spreads matching pods evenly across a
topology key (node, zone), within `maxSkew`. The spread is either strict
(`whenUnsatisfiable: DoNotSchedule`) or best-effort (`ScheduleAnyway`).
→ [10](../modules/10-scheduling/README.md)

## U

### User and group
Kubernetes has no User objects. A user or group is simply what the
authenticator asserts: the CN and O fields of a client certificate, or
claims in an OIDC token. RBAC binds to those names. Only ServiceAccounts
are real API objects.
→ [11](../modules/11-rbac/README.md)

## V

### ValidatingAdmissionPolicy
Validating admission written as CEL expressions, run inside the API server
(`admissionregistration.k8s.io/v1`, GA since v1.30). A
ValidatingAdmissionPolicyBinding applies it to resources. No webhook
server is needed.
→ [15](../modules/15-security/README.md)

### Volume
A directory that a pod's containers can use, declared in `spec.volumes`
and mounted with `volumeMounts`. Types include emptyDir, configMap,
secret, projected, downwardAPI, hostPath, persistentVolumeClaim, csi and
generic ephemeral volumes.
→ [06](../modules/06-storage/README.md)

### VolumeAttachment
A cluster-scoped `storage.k8s.io/v1` object that records that a CSI volume
should be attached to a specific node, and whether it is. The attach/detach
controller creates it. `kubectl get volumeattachments` shows where a block
volume is attached right now.
→ [troubleshooting](troubleshooting.md#multi-attach-error-volume-is-already-exclusively-attached-to-one-node)

### volumeBindingMode
A StorageClass field. `Immediate` binds and provisions as soon as the PVC
is created; `WaitForFirstConsumer` waits for a pod that uses it (see
below).
→ [06](../modules/06-storage/README.md)

### volumeClaimTemplates
A StatefulSet field: PVC templates from which the controller creates one
PVC per pod, named `<template>-<statefulset>-<ordinal>` (e.g.
`data-redis-0`). By default the PVCs are kept when you scale down or delete
the StatefulSet; `persistentVolumeClaimRetentionPolicy` changes that.
→ [07](../modules/07-statefulsets/README.md)

## W

### WaitForFirstConsumer
A StorageClass `volumeBindingMode`. Binding and provisioning wait until a
pod that uses the claim is scheduled, so the volume is created on a node
or in a zone where that pod can actually run. The PVC shows `Pending` until
then, which is normal. kind's `standard` class uses this mode.
→ [06](../modules/06-storage/README.md)

### Workload
Anything that runs on Kubernetes. It is usually managed by a workload
resource (Deployment, StatefulSet, DaemonSet, Job, CronJob) that creates
and replaces the pods for you.
→ [03](../modules/03-deployments/README.md)

---

Definitions follow the official
[Kubernetes glossary](https://kubernetes.io/docs/reference/glossary/) and
concept docs. If you find a term in this repo that isn't here, add it.
