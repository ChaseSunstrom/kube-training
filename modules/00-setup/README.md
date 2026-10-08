# 00 – Setup

## Goal

Install the tools, create the 3-node training cluster on your laptop, and get
comfortable enough with `kubectl` to find your own way around any cluster.

## What you'll learn

* How to install a container engine (Docker or Podman), `kubectl` and `kind` on Linux, macOS and Windows (WSL2)
* How to create (and re-create) the course cluster from [`cluster/kind-multi-node.yaml`](../../cluster/kind-multi-node.yaml)
* What a kubeconfig is: clusters, users, contexts, and the `kubectl config` commands
* The `kubectl` habits that make you fast: `explain`, `api-resources`, output formats (`-o wide|yaml|jsonpath|custom-columns`), `--dry-run=client -o yaml`, `diff`, completion and the `k` alias
* What every pod in `kube-system` does: kube-apiserver, etcd, kube-scheduler, kube-controller-manager, kubelet, kube-proxy, CoreDNS, the CNI plugin
* What actually happens, component by component, when you run `kubectl apply`

## Concepts

### What you are building

[kind](https://kind.sigs.k8s.io/) ("Kubernetes IN Docker") runs each Kubernetes
*node* as a container on your machine. Inside each node container there is a
real kubelet, a real container runtime (containerd) and real Linux networking,
so everything you learn here works the same on a cloud cluster.

```
your laptop
└── docker / podman
    ├── container "kube-training-control-plane"   ← control plane + host ports 80, 443, 30080
    │     kubelet, containerd, etcd, kube-apiserver, kube-scheduler, kube-controller-manager
    ├── container "kube-training-worker"          ← label training/zone=zone-a
    │     kubelet, containerd  → your pods run here...
    └── container "kube-training-worker2"         ← label training/zone=zone-b
          kubelet, containerd  → ...and here
```

The control-plane node carries the taint
`node-role.kubernetes.io/control-plane:NoSchedule`, so your workloads land on
the two workers (module 10 explains taints).

[`cluster/kind-multi-node.yaml`](../../cluster/kind-multi-node.yaml) is short; read it. It is a
kind `Cluster` object with a list of `nodes`, each with a `role`
(`control-plane` or `worker`) and optionally:

* `labels:` – Kubernetes node labels kind applies when the node joins. The
  control plane gets `ingress-ready: "true"` (the ingress module schedules its
  controller there), the workers get `training/zone: zone-a` / `zone-b` (used
  to demonstrate zone-aware scheduling). See them with `kubectl get nodes --show-labels`.
* `extraPortMappings:` – publish a port of the node *container* on your
  machine, like `docker run -p`. The control plane publishes 80, 443 (ingress)
  and 30080 (the NodePort used in module 04).

### The control plane and node components

| Component | Runs as (in kind) | What it does |
|---|---|---|
| **kube-apiserver** | static pod on the control plane | The front door. Every client (kubectl, controllers, kubelets) talks only to it, over HTTPS. Authenticates, authorizes (RBAC), runs admission, validates, and stores objects in etcd. The only component that talks to etcd. |
| **etcd** | static pod on the control plane | Consistent key-value store holding the entire cluster state. Lose it without a backup and you lose the cluster. |
| **kube-scheduler** | static pod on the control plane | Watches for pods with no `spec.nodeName`, filters nodes that *can* run them (resources, taints, affinity…), scores the rest and writes the winner into the pod (a "binding"). It does not start anything. |
| **kube-controller-manager** | static pod on the control plane | Runs dozens of control loops in one binary: Deployment, ReplicaSet, Job, Node, EndpointSlice, ServiceAccount, namespace deletion, garbage collector… Each loop compares *desired* state (spec) with *actual* state and acts to close the gap. |
| **kubelet** | systemd service on **every** node (not a pod!) | The node agent. Watches for pods bound to its node, asks the container runtime to run them, runs probes, mounts volumes, reports status back to the API server. Also runs the *static pods* found in `/etc/kubernetes/manifests`. |
| **containerd** | systemd service on every node | The container runtime. The kubelet talks to it through the CRI (Container Runtime Interface). (Docker itself is no longer used *inside* Kubernetes – "dockershim" was removed in 1.24.) |
| **kube-proxy** | DaemonSet (one pod per node) | Turns Services into packet-forwarding rules (iptables here) on every node, so a Service's virtual IP reaches a real pod. Module 04. |
| **CNI plugin** (kindnet) | DaemonSet + binaries in `/opt/cni/bin` | Gives every pod an IP and routes pod-to-pod traffic between nodes. Kubernetes only defines the interface; kind ships *kindnet*, clouds use Calico, Cilium, AWS VPC CNI, … |
| **CoreDNS** | Deployment (2 pods) behind Service `kube-dns` (10.96.0.10) | Cluster DNS: `my-svc.my-namespace.svc.cluster.local` → Service IP. Module 04. |
| local-path-provisioner | Deployment in `local-path-storage` | kind's default StorageClass `standard`: creates PersistentVolumes as directories on the node. Module 06. |

A **static pod** is a pod the kubelet starts directly from a file on disk,
without the API server or scheduler (that is how the control plane bootstraps
itself). The kubelet creates a read-only "mirror pod" in the API so you can
see it with `kubectl`, owned by the Node object.

### Everything is "declare, then reconcile"

You never tell Kubernetes *do X*. You store an object that says *I want X*
(`spec`), and controllers keep working until reality (`status`) matches.
Components never call each other; they all **watch** the API server and react
to changes. That is why the system self-heals: if a pod dies, the ReplicaSet
controller notices "want 2, have 1" and creates another.

### What happens when you run `kubectl apply -f deploy.yaml`

```
 kubectl ─┐ 1. reads ~/.kube/config: which server, which credentials
          │ 2. GET the object; computes what changed (client-side apply)
          ▼ 3. HTTPS PATCH/POST to the API server
 kube-apiserver
   4. authentication   who are you?           (client certificate in kind)
   5. authorization    are you allowed?       (RBAC, module 11)
   6. mutating admission   fills in defaults  (serviceAccount, tolerations, ...)
   7. schema validation + validating admission (e.g. Pod Security, quotas)
   8. write to etcd  → returns 201 Created / 200 OK  ← kubectl prints "created"
          │
          │ watch events fan out to everyone who cares:
          ▼
 deployment controller  → creates a ReplicaSet
 replicaset controller  → creates N Pods (spec.nodeName empty)
 kube-scheduler         → picks a node, writes spec.nodeName
 kubelet on that node   → pulls image via containerd, CNI sets up the pod network,
                          starts containers, runs probes, updates pod status
 EndpointSlice controller + kube-proxy → once pods are Ready, Services route to them
```

`kubectl apply` returns at step 8. Everything after that is asynchronous,
which is why you `kubectl get -w`, `kubectl rollout status` or `kubectl wait`
to see the result.

### kubeconfig: clusters, users, contexts

`kubectl` reads `~/.kube/config` (or every file listed in the `KUBECONFIG`
environment variable, merged). It holds three lists:

* **clusters** – API server URL + the CA certificate to trust
* **users** – credentials (client cert, token, or an exec plugin such as `aws eks get-token`)
* **contexts** – a named triple *cluster + user + default namespace*

`current-context` picks the one used by default. `kind create cluster` adds a
context called `kind-<cluster name>`, so ours is **`kind-kube-training`**.

## Files

| File | What it demonstrates |
|---|---|
| [`00-namespace.yaml`](00-namespace.yaml) | The `lab-setup` namespace used by this module |
| [`01-hello-pod.yaml`](01-hello-pod.yaml) | Your first pod (nginx) – spec vs status, what the server adds |
| [`02-hello-deployment.yaml`](02-hello-deployment.yaml) | A Deployment used to watch one `apply` flow through controller → scheduler → kubelet |
| [`check-setup.sh`](check-setup.sh) | Read-only checker: tools installed, versions compatible, cluster healthy |
| [`shell-setup.sh`](shell-setup.sh) | Optional: kubectl completion, `k` alias, `$dry`, `kctx`/`kns` helpers for bash/zsh |
| [`solutions/`](solutions/) | Reference answers for exercises 2–4 |

## Lab

### 1. Install the tools

You need **a container engine**, **kubectl** and **kind**. Budget at least
**4 GB of RAM and 2 CPUs** for the container engine (6–8 GB is comfortable);
if your machine has less, use the single-node cluster in step 2.

The course targets **Kubernetes 1.37** (kind v0.33.0, whose default node
image is `kindest/node:v1.37.0`, and kubectl v1.37.x). Other versions mostly
work, but keep `kubectl` within **one minor version** of the cluster – that
is the official version-skew policy.

<details open>
<summary><b>Linux (incl. WSL2)</b></summary>

```bash
# --- Docker Engine (or follow https://docs.docker.com/engine/install/ for your distro)
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker "$USER"      # then log out and back in, so you don't need sudo
docker run --rm busybox:1.37 echo docker works

# --- kubectl (pinned to the course version; use arm64 instead of amd64 on ARM machines)
curl -LO "https://dl.k8s.io/release/v1.37.1/bin/linux/amd64/kubectl"
curl -LO "https://dl.k8s.io/release/v1.37.1/bin/linux/amd64/kubectl.sha256"
echo "$(cat kubectl.sha256)  kubectl" | sha256sum --check      # must print: kubectl: OK
sudo install -m 0755 kubectl /usr/local/bin/kubectl && rm kubectl kubectl.sha256

# --- kind
curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.33.0/kind-linux-amd64
sudo install -m 0755 kind /usr/local/bin/kind && rm kind
```

Kubernetes 1.37 expects a **cgroup v2** host – recent kubelets refuse to
start on cgroup v1 by default, and kind warns that cgroup v1 support is going
away. Check with `stat -fc %T /sys/fs/cgroup/`: it must print `cgroup2fs`
(all current distributions do; very old ones such as Ubuntu 20.04 or
CentOS 7 print `tmpfs` and need an upgrade).

Multi-node kind clusters on Linux can hit the default inotify limits
(symptom: pods fail with "too many open files"). Raise them once:

```bash
sudo tee /etc/sysctl.d/99-kind.conf <<'EOF'
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 512
EOF
sudo sysctl --system
```
</details>

<details>
<summary><b>macOS</b></summary>

```bash
# --- Container engine: install Docker Desktop (https://docs.docker.com/desktop/setup/install/mac-install/)
#     then Settings → Resources → Memory: at least 4 GB (6-8 GB is better).
#     Alternatives: OrbStack, Colima (`brew install colima docker && colima start --cpu 4 --memory 6`),
#     or Podman (see below).

# --- kubectl, pinned (Apple Silicon = arm64, Intel = amd64)
curl -LO "https://dl.k8s.io/release/v1.37.1/bin/darwin/arm64/kubectl"
chmod +x kubectl && sudo mv kubectl /usr/local/bin/kubectl
#     (`brew install kubectl` gives you the newest kubectl; fine only if your
#      cluster is within one minor version of it)

# --- kind
brew install kind        # or: curl -Lo kind https://kind.sigs.k8s.io/dl/v0.33.0/kind-darwin-arm64
```
</details>

<details>
<summary><b>Windows</b></summary>

Use **WSL2** – everything in this course is written for a Linux shell.

1. In an admin PowerShell: `wsl --install -d Ubuntu`, reboot, open "Ubuntu".
2. Container engine, either:
   * **Docker Desktop** with the WSL2 backend: *Settings → Resources → WSL integration →* enable your Ubuntu distro; or
   * Docker Engine installed *inside* WSL2 (Linux instructions above; enable systemd first by putting `[boot]` / `systemd=true` in `/etc/wsl.conf`, then `wsl --shutdown` from PowerShell).
3. Inside Ubuntu, install `kubectl` and `kind` exactly as in the **Linux** section.
4. Check `which kubectl` says `/usr/local/bin/kubectl`. Docker Desktop also puts a
   `kubectl` on your PATH, which may be a different version.

Ports published by kind inside WSL2 (80, 443, 30080) are reachable from your
Windows browser as `http://localhost:<port>`.
</details>

<details>
<summary><b>Podman instead of Docker</b></summary>

kind supports Podman as an "experimental provider". Tell kind to use it in every shell:

```bash
export KIND_EXPERIMENTAL_PROVIDER=podman
```

* macOS/Windows: the Podman machine must be rootful and big enough:
  `podman machine init --cpus 4 --memory 6144 --rootful && podman machine start`.
* Linux rootless Podman needs cgroup v2 delegation and cannot bind ports below 1024
  by default (our config maps 80/443). See kind's
  [rootless guide](https://kind.sigs.k8s.io/docs/user/rootless/), or run kind with `sudo`.
* Everywhere this course says `docker exec …` / `docker inspect …`, use `podman exec …` / `podman inspect …`.
</details>

<details>
<summary><b>Alternatives: minikube or k3d (not the supported path)</b></summary>

The manifests are plain Kubernetes, so most of the course works on any
cluster, but READMEs assume kind's node names, labels and port mappings.

| | minikube | k3d (k3s in Docker) |
|---|---|---|
| Create a similar cluster | `minikube start -p kube-training --driver=docker --nodes=3 --kubernetes-version=v1.37.0` (if your minikube release supports it) | `k3d cluster create kube-training --agents 2 -p "30080:30080@server:0"` (choose the Kubernetes version with `--image rancher/k3s:<tag>`) |
| Reach NodePort 30080 | `minikube -p kube-training service <svc> -n <ns> --url` | `http://localhost:30080` (thanks to `-p`) |
| Default StorageClass | `standard` (hostpath, binds immediately) | `local-path` – edit `storageClassName` in module 06 |
| Differences to watch | no `training/zone` labels: add them with `kubectl label node` | ships Traefik ingress + a LoadBalancer implementation (servicelb) and flannel CNI |
</details>

Now check everything in one go:

```bash
bash modules/00-setup/check-setup.sh
```

Before the cluster exists you will see the tools pass and step 4 fail – that is expected.

### 2. Create the cluster

From the repo root:

```bash
kind create cluster --config cluster/kind-multi-node.yaml
```

```
Creating cluster "kube-training" ...
 ✓ Ensuring node image (kindest/node:v1.37.0) 🖼
 ✓ Preparing nodes 📦 📦 📦
 ✓ Writing configuration 📜
 ✓ Starting control-plane 🕹️
 ✓ Installing CNI 🔌
 ✓ Installing StorageClass 💾
 ✓ Joining worker nodes 🚜
Set kubectl context to "kind-kube-training"
```

* The first run downloads the ~450 MB node image; later runs take ~1 minute.
* Using a different kind release, but want exactly the targeted Kubernetes
  version? Add `--image kindest/node:v1.37.0`.
* "address already in use" → something on your machine already listens on
  port 80, 443 or 30080. Stop it, or (temporarily) delete those
  `extraPortMappings` from a *copy* of the config.
* **Low on RAM?** Use the single-node config instead – one node does
  everything (kind removes the control-plane taint so pods can run on it):

  ```bash
  kind create cluster --config cluster/kind-single-node.yaml
  ```

  It has no host port mappings, so where a module uses `http://localhost:30080`
  or `http://localhost`, use `kubectl port-forward` instead. Scheduling
  exercises that need two workers behave differently; the modules say where.

Check it:

```bash
kubectl get nodes -o wide
```

```
NAME                          STATUS   ROLES           AGE   VERSION   INTERNAL-IP   ...   CONTAINER-RUNTIME
kube-training-control-plane   Ready    control-plane   31m   v1.37.0   172.18.0.4    ...   containerd://2.3.4
kube-training-worker          Ready    <none>          31m   v1.37.0   172.18.0.3    ...   containerd://2.3.4
kube-training-worker2         Ready    <none>          31m   v1.37.0   172.18.0.2    ...   containerd://2.3.4
```

Nodes are `NotReady` for the first ~20 seconds, until the CNI plugin is
running. Then run the checker again – everything should be `[ ok ]`:

```bash
bash modules/00-setup/check-setup.sh
```

```
4. Cluster
  [ ok ] current context is kind-kube-training
  [ ok ] server version v1.37.0
  [ ok ] kubectl/server skew is 0 minor version(s)
  [ ok ] 3/3 nodes Ready
  [ ok ] all kube-system pods Running
  [ ok ] default StorageClass: standard
```

The nodes are just containers – `docker ps` shows them. Stopping Docker stops
the cluster; it normally comes back when Docker starts again. If it ever
misbehaves after a reboot, recreate it: nothing in this course needs to
survive (`kind delete cluster --name kube-training`, then step 2 again).

### 3. Look at your kubeconfig and contexts

```bash
kubectl config get-contexts
kubectl config current-context
kubectl config view --minify          # only the current context; secrets shown as DATA+OMITTED
```

```
CURRENT   NAME                 CLUSTER              AUTHINFO             NAMESPACE
*         kind-kube-training   kind-kube-training   kind-kube-training
```

```yaml
clusters:
- cluster:
    certificate-authority-data: DATA+OMITTED
    server: https://127.0.0.1:39241        # kind publishes the API server on a random localhost port
  name: kind-kube-training
contexts:
- context:
    cluster: kind-kube-training
    user: kind-kube-training
  name: kind-kube-training
current-context: kind-kube-training
users:
- name: kind-kube-training
  user:
    client-certificate-data: DATA+OMITTED  # you authenticate with a client certificate
    client-key-data: DATA+OMITTED
```

The commands you will use most:

| Command | What it does |
|---|---|
| `kubectl config get-contexts` | List contexts; `*` marks the current one |
| `kubectl config use-context kind-kube-training` | Switch cluster (do this *every time* you have several – the classic mistake is running a command against the wrong cluster) |
| `kubectl config set-context --current --namespace=lab-pods` | Change the default namespace of the current context |
| `kubectl config view --minify -o jsonpath='{..namespace}'` | Print the current default namespace (empty = `default`) |
| `kind export kubeconfig --name kube-training` | Re-add the context if you deleted it or switched machines |
| `KUBECONFIG=~/.kube/config:~/other.yaml kubectl config view --flatten` | Merge several kubeconfig files into one |

This course always passes `-n <namespace>` explicitly, so you do not need to
change the default namespace – but it is handy while exploring. Popular
helpers: [kubectx/kubens](https://github.com/ahmetb/kubectx), or `kns` from
`shell-setup.sh` below.

### 4. Your first pod

```bash
kubectl apply -f modules/00-setup/00-namespace.yaml
kubectl apply -f modules/00-setup/01-hello-pod.yaml
kubectl get pods -n lab-setup -o wide
```

```
namespace/lab-setup created
pod/hello created
NAME    READY   STATUS    RESTARTS   AGE   IP            NODE                    NOMINATED NODE   READINESS GATES
hello   1/1     Running   0          2s    10.244.1.17   kube-training-worker2   <none>           <none>
```

Talk to it, read its logs, run a command inside it:

```bash
kubectl port-forward pod/hello 8080:80 -n lab-setup     # leave running; open http://localhost:8080, Ctrl-C to stop
kubectl logs hello -n lab-setup                         # nginx access log shows your request
kubectl exec hello -n lab-setup -- nginx -v             # one-off command
kubectl exec -it hello -n lab-setup -- sh               # interactive shell (exit with Ctrl-D)
kubectl describe pod hello -n lab-setup                 # human summary + Events at the bottom
```

Now compare the ~30 lines you wrote with what the server stored:

```bash
kubectl get pod hello -n lab-setup -o yaml
```

Things you did **not** write, and who added them:

* `status:` – filled in by the kubelet (phase, podIP, conditions, container states).
* `nodeName: kube-training-worker2` – written by the scheduler.
* `serviceAccountName: default` and a `kube-api-access-xxxxx` volume – the ServiceAccount admission plugin.
* `tolerations` for `not-ready`/`unreachable` with `tolerationSeconds: 300` – the DefaultTolerationSeconds admission plugin (how long the pod survives on a dead node).
* `restartPolicy: Always`, `dnsPolicy: ClusterFirst`, `terminationGracePeriodSeconds: 30`, `imagePullPolicy: IfNotPresent` – API defaults.
* `metadata.annotations.kubectl.kubernetes.io/last-applied-configuration` – written by `kubectl apply` itself, so the *next* apply can work out which fields you removed.

### 5. Output formats you will use every day

```bash
kubectl get pods -n lab-setup -o wide                  # + IP, node
kubectl get pod hello -n lab-setup -o yaml             # the full object (also -o json)
kubectl get pod hello -n lab-setup -o jsonpath='{.status.podIP}{"\n"}'
kubectl get pods -n lab-setup -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.nodeName}{"\n"}{end}'
kubectl get pods -n lab-setup -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeName,IMAGE:.spec.containers[0].image,PHASE:.status.phase
kubectl get pods -A                                    # all namespaces
kubectl get pods -A --field-selector spec.nodeName=kube-training-worker   # everything on one node
kubectl get pods -n lab-setup -w                       # watch for changes (Ctrl-C to stop)
```

```
10.244.1.17

NAME     NODE                    IMAGE               PHASE
hello    kube-training-worker2   nginx:1.27-alpine   Running
```

`jsonpath` and `custom-columns` paths are exactly the field paths you see in
`-o yaml`. When in doubt, look at the YAML first, then write the path.

### 6. Let the cluster teach you: `explain` and `api-resources`

You do not need to memorise YAML. The API server publishes its schema:

```bash
kubectl explain pod.spec.restartPolicy
kubectl explain deployment.spec.strategy
kubectl explain pod.spec.containers --recursive | less     # the whole tree, field names only
```

```
KIND:       Pod
VERSION:    v1

FIELD: restartPolicy <string>
ENUM:
    Always
    Never
    OnFailure

DESCRIPTION:
    Restart policy for all containers within the pod. One of Always, OnFailure,
    Never. In some contexts, only a subset of those values may be permitted.
    Default to Always.
```

And to list every kind of object this cluster knows, with short names and
API groups:

```bash
kubectl api-resources                       # NAME, SHORTNAMES, APIVERSION, NAMESPACED, KIND
kubectl api-resources --namespaced=false    # cluster-scoped: nodes, namespaces, PVs, ClusterRoles, ...
kubectl api-resources --api-group=apps      # deployments, replicasets, statefulsets, daemonsets, ...
```

```
NAME          SHORTNAMES   APIVERSION   NAMESPACED   KIND
configmaps    cm           v1           true         ConfigMap
endpoints     ep           v1           true         Endpoints
...
```

The `SHORTNAMES` column is why `kubectl get po,svc,deploy` works.

### 7. Generate YAML instead of typing it: `--dry-run=client -o yaml`

Imperative commands are a quick way to *generate* a starting manifest:

```bash
kubectl create deployment demo --image=nginx:1.27-alpine --replicas=2 -n lab-setup --dry-run=client -o yaml
kubectl run demo --image=nginx:1.27-alpine -n lab-setup --dry-run=client -o yaml > pod.yaml
```

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  labels:
    app: demo
  name: demo
  namespace: lab-setup
spec:
  replicas: 2
  selector:
    matchLabels:
      app: demo
  ...
```

Nothing is sent to the cluster. Delete the `strategy: {}`,
`resources: {}` and `status: {}` noise, add resources/probes, and you have a
real manifest. Two related tools:

```bash
kubectl apply -f modules/00-setup/ --dry-run=server   # the API server validates + runs admission, stores nothing
kubectl diff -f modules/00-setup/01-hello-pod.yaml    # what WOULD change (exit code 0 = no changes, 1 = changes)
```

### 8. Shell completion and the `k` alias (optional, but you will thank yourself)

```bash
source modules/00-setup/shell-setup.sh       # bash or zsh, current shell only
k get po -n lab-<TAB>                        # completes namespaces, pod names, flags...
k create deployment x --image=nginx:1.27-alpine $dry
kctx                                         # prints current context + namespace
```

Read [`shell-setup.sh`](shell-setup.sh) – it is short – and add the `source`
line to your `~/.bashrc` / `~/.zshrc` to keep it. On fish:
`kubectl completion fish | source`; on PowerShell:
`kubectl completion powershell | Out-String | Invoke-Expression`.

### 9. Tour of `kube-system`

```bash
kubectl get pods -n kube-system -o wide
```

```
NAME                                                  READY   STATUS    IP           NODE
coredns-674b8bbfcf-cb9kz                              1/1     Running   10.244.0.4   kube-training-control-plane
coredns-674b8bbfcf-rdnpp                              1/1     Running   10.244.0.3   kube-training-control-plane
etcd-kube-training-control-plane                      1/1     Running   172.18.0.4   kube-training-control-plane
kindnet-89lnw                                         1/1     Running   172.18.0.2   kube-training-worker2
kindnet-hd5h9                                         1/1     Running   172.18.0.4   kube-training-control-plane
kindnet-hpxkk                                         1/1     Running   172.18.0.3   kube-training-worker
kube-apiserver-kube-training-control-plane            1/1     Running   172.18.0.4   kube-training-control-plane
kube-controller-manager-kube-training-control-plane   1/1     Running   172.18.0.4   kube-training-control-plane
kube-proxy-2rwl6                                      1/1     Running   172.18.0.4   kube-training-control-plane
kube-proxy-m79rp                                      1/1     Running   172.18.0.2   kube-training-worker2
kube-proxy-xfzzm                                      1/1     Running   172.18.0.3   kube-training-worker
kube-scheduler-kube-training-control-plane            1/1     Running   172.18.0.4   kube-training-control-plane
```

Read it like an engineer:

* **Names ending in `-kube-training-control-plane`** (etcd, apiserver,
  controller-manager, scheduler) are static pods. Prove it:

  ```bash
  docker exec kube-training-control-plane ls /etc/kubernetes/manifests
  kubectl get pod -n kube-system kube-apiserver-kube-training-control-plane \
    -o jsonpath='{.metadata.ownerReferences[0].kind}/{.metadata.ownerReferences[0].name}{"\n"}'
  ```
  ```
  etcd.yaml
  kube-apiserver.yaml
  kube-controller-manager.yaml
  kube-scheduler.yaml
  Node/kube-training-control-plane
  ```
  Deleting such a mirror pod with `kubectl` does nothing lasting – the kubelet
  recreates it from the file.
* **IPs `172.18.0.x`** are node IPs: these pods use `hostNetwork: true` (the
  control plane, kube-proxy and the CNI agent must run *before* pod networking
  exists). **IPs `10.244.x.y`** are pod IPs handed out by the CNI; each node
  owns a `/24` (`kubectl get nodes -o custom-columns=NAME:.metadata.name,PODCIDR:.spec.podCIDR`).
* **`kindnet-*` and `kube-proxy-*`** appear once per node: they are DaemonSets
  (module 09). **`coredns-*`** has a ReplicaSet hash in its name: it is a Deployment.

  ```bash
  kubectl get deployments,daemonsets -n kube-system
  kubectl get service kube-dns -n kube-system       # CLUSTER-IP 10.96.0.10 - every pod's DNS server
  ```
* **The kubelet is missing from the list** – it is not a pod, it is the thing
  that *runs* pods. Look at it and at containerd directly on a node:

  ```bash
  docker exec kube-training-worker systemctl status kubelet --no-pager | head -4
  docker exec kube-training-worker crictl ps          # containers as containerd sees them
  docker exec kube-training-worker ls /etc/cni/net.d  # the CNI config the kubelet/containerd use
  ```
  ```
  ● kubelet.service - kubelet: The Kubernetes Node Agent
       Loaded: loaded (/etc/systemd/system/kubelet.service; enabled; preset: enabled)
       Active: active (running) since ...
  CONTAINER      IMAGE          STATE     NAME          ATTEMPT   POD ID         POD                NAMESPACE
  6280e4967a7cc  409467f978b4a  Running   kindnet-cni   0         e156bc205dd1e  kindnet-hpxkk      kube-system
  11624315c92ae  b79c189b052cd  Running   kube-proxy    0         27e390c7b4189  kube-proxy-xfzzm   kube-system
  10-kindnet.conflist
  ```
* Controller-manager and scheduler use **leader election** via Lease objects,
  so in an HA cluster with 3 control-plane nodes only one of each is active:
  `kubectl get leases -n kube-system`.
* Health of the API server itself: `kubectl get --raw='/readyz?verbose'`.

### 10. Watch one `kubectl apply` flow through the system

Apply the Deployment and immediately list the events, oldest first, with the
component that reported each one:

```bash
kubectl apply -f modules/00-setup/02-hello-deployment.yaml
kubectl rollout status deployment/hello -n lab-setup
kubectl get events -n lab-setup --sort-by=.metadata.creationTimestamp \
  -o custom-columns=WHO:.source.component,REASON:.reason,OBJECT:.involvedObject.name,MESSAGE:.message
```

```
WHO                     REASON              OBJECT                   MESSAGE
deployment-controller   ScalingReplicaSet   hello                    Scaled up replica set hello-777bd99564 from 0 to 2
replicaset-controller   SuccessfulCreate    hello-777bd99564         Created pod: hello-777bd99564-pbrps
replicaset-controller   SuccessfulCreate    hello-777bd99564         Created pod: hello-777bd99564-55ngt
default-scheduler       Scheduled           hello-777bd99564-55ngt   Successfully assigned lab-setup/hello-777bd99564-55ngt to kube-training-worker2
default-scheduler       Scheduled           hello-777bd99564-pbrps   Successfully assigned lab-setup/hello-777bd99564-pbrps to kube-training-worker
kubelet                 Pulled              hello-777bd99564-pbrps   Container image "traefik/whoami:v1.10" already present on machine and can be accessed by the pod
kubelet                 Created             hello-777bd99564-pbrps   Container created
kubelet                 Started             hello-777bd99564-pbrps   Container started
...
```

That is the diagram from *Concepts*, as it happened: the deployment
controller made a ReplicaSet, the ReplicaSet controller made two pods, the
scheduler placed them on different workers, and each node's kubelet started
its container. (You will also see the events of the `hello` pod from step 4.
Events that happen within the same second may be listed in any order.
Events are kept for one hour by default.)

Now see the HTTP requests `kubectl` itself makes (`-v=6` logs each request;
`-v=8` adds the bodies):

```bash
kubectl apply -f modules/00-setup/02-hello-deployment.yaml -v=6 2>&1 | grep -E 'GET|POST|PATCH'
```

On the first apply you see a `GET .../deployments/hello` answered with `404 Not Found`, then
`POST .../namespaces/lab-setup/deployments ... 201 Created`. Run it again unchanged and the GET
returns `200 OK` and no write is sent at all – `apply` only sends what differs.

Finally, the self-healing loop in action:

```bash
kubectl delete pod -n lab-setup -l app=hello-deploy --wait=false
kubectl get pods -n lab-setup -l app=hello-deploy -w
```

While the old pods are still `Terminating`, two **new** pods (new names)
appear as `Pending` and are `Running` a second or two later: the ReplicaSet
controller saw "want 2, have 0" (pods that are terminating no longer count). The bare `hello` pod from
step 4 has no controller; delete it and it stays gone.

## Exercises

1. **Find things without the docs.** Using only `kubectl explain` and
   `kubectl api-resources`, answer: (a) what is the short name of
   `persistentvolumeclaims`? (b) Is a `Lease` namespaced? (c) What are the
   allowed values of `pod.spec.containers.imagePullPolicy`, and what is the
   default for an image pinned to a tag?
   *Hint:* `kubectl api-resources | grep -i lease`; `kubectl explain pod.spec.containers.imagePullPolicy`.
   <details><summary>Answers</summary>

   (a) `pvc`. (b) Yes – `leases` (`coordination.k8s.io/v1`) shows `NAMESPACED true`; node
   heartbeats live in `kube-node-lease`, leader-election leases in `kube-system`.
   (c) `Always`, `IfNotPresent`, `Never`; the default is `IfNotPresent` for a pinned tag and
   `Always` for `:latest` or no tag (one more reason to pin).
   </details>

2. **jsonpath drill.** Print one line per node with its name, its pod CIDR
   and its kubelet version, then print only the names of pods in
   `kube-system` that run on the control-plane node.
   *Hint:* `.status.nodeInfo.kubeletVersion`; `--field-selector spec.nodeName=...`;
   `-o jsonpath='{range .items[*]}...{"\n"}{end}'`.
   Solution: [`solutions/ex2-jsonpath.sh`](solutions/ex2-jsonpath.sh).

3. **Generate, edit, apply.** Use `kubectl create deployment` with
   `--dry-run=client -o yaml` to generate a Deployment `web` in `lab-setup`
   with 3 replicas of `nginx:1.27-alpine`, save it to a file, add CPU/memory
   requests and limits, then `kubectl diff` and `kubectl apply` it.
   Verify with `kubectl get pods -n lab-setup -l app=web -o wide` that the pods are spread over both workers.
   Solution: [`solutions/ex3-web-deployment.yaml`](solutions/ex3-web-deployment.yaml).

4. **A context of your own.** Create a second context `kt-setup` that uses
   the same cluster and user as `kind-kube-training` but defaults to the
   `lab-setup` namespace. Switch to it, run `kubectl get pods` (no `-n`), then
   switch back and delete the context.
   *Hint:* `kubectl config set-context kt-setup --cluster=... --user=... --namespace=...`;
   `kubectl config delete-context`.
   Solution: [`solutions/ex4-context.sh`](solutions/ex4-context.sh).

5. **Break the control plane (safely).** Static pods are just files. Move the
   scheduler manifest out of the manifests directory, create a pod, and
   observe it stay `Pending` with *no* events at all. Put the file back and
   watch the pod get scheduled.
   ```bash
   docker exec kube-training-control-plane mv /etc/kubernetes/manifests/kube-scheduler.yaml /root/
   kubectl run pending-demo --image=nginx:1.27-alpine -n lab-setup
   kubectl get pod pending-demo -n lab-setup -w      # Pending... forever
   docker exec kube-training-control-plane mv /root/kube-scheduler.yaml /etc/kubernetes/manifests/
   ```
   *Why no events?* The "FailedScheduling" event is written by the scheduler.
   No scheduler, no one even looks at the pod (`kubectl describe` shows
   `Events: <none>`). A few seconds after the file is back, the kubelet
   restarts the scheduler and the pod gets a `Scheduled` event. Do this only on
   your own laptop cluster, always put the file back, and finish with
   `kubectl delete pod pending-demo -n lab-setup`.

## Cleanup

```bash
kubectl delete namespace lab-setup
```

Keep the cluster – every following module uses it. When you are completely
done with the course: `kind delete cluster --name kube-training`.

## Further reading

* [Install and set up kubectl](https://kubernetes.io/docs/tasks/tools/) – and [optional kubectl configurations (completion)](https://kubernetes.io/docs/tasks/tools/included/optional-kubectl-configs-bash-linux/)
* [kind quick start](https://kind.sigs.k8s.io/docs/user/quick-start/) and [kind known issues](https://kind.sigs.k8s.io/docs/user/known-issues/)
* [Kubernetes components](https://kubernetes.io/docs/concepts/overview/components/)
* [Cluster architecture](https://kubernetes.io/docs/concepts/architecture/) and [controllers](https://kubernetes.io/docs/concepts/architecture/controller/)
* [Organizing cluster access using kubeconfig files](https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/)
* [kubectl quick reference](https://kubernetes.io/docs/reference/kubectl/quick-reference/) and [JSONPath support](https://kubernetes.io/docs/reference/kubectl/jsonpath/)
* [Static pods](https://kubernetes.io/docs/tasks/configure-pod-container/static-pod/)
* [Controlling access to the API (authn → authz → admission)](https://kubernetes.io/docs/concepts/security/controlling-access/)
* [Version skew policy](https://kubernetes.io/releases/version-skew-policy/)
