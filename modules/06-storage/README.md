# Module 06 – Storage

## Goal

Give pods storage that matches the job, from scratch space that lives as long
as the pod to persistent volumes that outlive it. Understand exactly how
PersistentVolumes, PersistentVolumeClaims, StorageClasses and access modes
fit together.

## What you'll learn

* `emptyDir` (disk and `medium: Memory`, `sizeLimit`) and `hostPath`, and why
  `hostPath` is dangerous.
* Static provisioning (you create the PV) and dynamic provisioning (a
  StorageClass creates it).
* Custom StorageClasses: `reclaimPolicy: Retain` and what it means after the
  PVC is gone, and `volumeBindingMode` `Immediate` vs `WaitForFirstConsumer`.
* Access modes **RWO / ROX / RWX / RWOP**, precisely: RWO is per **node**,
  RWOP is per **pod**. Which backends support what, and where the
  `Multi-Attach` error comes from.
* Data persistence across pod deletion, the PV/PVC lifecycle (Available,
  Bound, Released, Failed) and the protection finalizers.
* Volume expansion and VolumeSnapshots (concepts; kind's storage supports
  neither).

## Concepts

### Volumes: three lifetimes

| Kind | Lives as long as | Examples |
|---|---|---|
| **Ephemeral, pod-scoped** | the pod (survives container restarts) | `emptyDir`, `configMap`, `secret`, `projected`, `downwardAPI` |
| **Node-scoped** | the node's disk | `hostPath` |
| **Persistent** | until someone deletes the PV (or the reclaim policy does) | `persistentVolumeClaim` → PV backed by a cloud disk, NFS, local disk … |

### PV, PVC, StorageClass

```
  Pod ──volumes[].persistentVolumeClaim──▶ PVC  (namespaced)
                                            │   "I need 200Mi, ReadWriteOnce, class standard"
                                            │   binds 1:1, exclusively
                                            ▼
                                            PV   (cluster-scoped)
                                                 a real piece of storage
                                            ▲
            static:  an admin creates it ───┤
            dynamic: the provisioner named ─┘
                     in a StorageClass creates it when a PVC asks
```

* **PersistentVolumeClaim (PVC)**: what an app *asks for*: size, access mode,
  class. Pods only ever reference PVCs.
* **PersistentVolume (PV)**: what the cluster *has*: a disk, a directory or a
  share, with capacity, access modes, a reclaim policy and optionally node
  affinity.
* **StorageClass**: a recipe for making PVs on demand: `provisioner`,
  `parameters`, `reclaimPolicy`, `volumeBindingMode`, `allowVolumeExpansion`.
  One class can be the **default** (annotation
  `storageclass.kubernetes.io/is-default-class: "true"`). A PVC that doesn't
  set `storageClassName` gets the default. A PVC that sets
  `storageClassName: ""` explicitly opts out and only binds to class-less PVs.

In kind, the default class `standard` uses the **rancher local-path**
provisioner. It creates a directory under `/var/local-path-provisioner/` on the
node where the pod was scheduled, then a `hostPath` PV with **node affinity**
to that node. It supports RWO and RWOP and nothing else, and it cannot resize.

### Binding mode: Immediate vs WaitForFirstConsumer

| `volumeBindingMode` | Volume is provisioned/bound… | Good for | Problem |
|---|---|---|---|
| `Immediate` (default if unset) | as soon as the PVC is created | storage reachable from every node (NFS, most RWX file systems) | the volume may land in a zone or node where the pod can't run; node-local provisioners can't work at all |
| `WaitForFirstConsumer` | after the scheduler has placed the first pod that uses the PVC | node-local storage, zonal cloud disks; what most cloud default classes use | the PVC looks "stuck" in `Pending` until a pod uses it, which is normal |

### Access modes, precisely

| Mode | Short | What it really means |
|---|---|---|
| `ReadWriteOnce` | RWO | mounted read-write by **one node** at a time. **Any number of pods on that node** can use it simultaneously. |
| `ReadOnlyMany` | ROX | mounted read-only by many nodes. |
| `ReadWriteMany` | RWX | mounted read-write by many nodes. |
| `ReadWriteOncePod` | RWOP | mounted read-write by **one pod** in the whole cluster. The scheduler refuses a second pod, even on the same node. GA since 1.29. |

Three facts people get wrong:

1. **RWO is not "one pod".** Two pods on the same node can mount the same
   RWO volume read-write (lab step 9). If you need one pod, use RWOP.
2. **Access modes are not permissions.** They are used to match PVCs to PVs
   and to decide where a volume may be attached. They don't make a mount
   read-only. Use `readOnly: true` on the `volumeMount` (or on
   `persistentVolumeClaim`) for that.
3. **A PV lists what the backend can do. A PVC asks for a subset.** The PVC
   is bound only if the PV offers every mode it asks for.

What typical backends support (always check your CSI driver's docs):

| Backend type | Examples | RWO | ROX | RWX | RWOP |
|---|---|---|---|---|---|
| Node-local | kind/k3s `local-path`, `local` PVs, `hostPath` | ✓ | – | – | ✓ local-path (scheduler-enforced) |
| Cloud block disk (CSI) | AWS EBS, GCE Persistent Disk, Azure Disk | ✓ | GCE PD only | – ¹ | ✓ |
| Network file system | NFS, AWS EFS, Azure Files, GCP Filestore, CephFS | ✓ | ✓ | ✓ | ✓ (CSI drivers) |
| Distributed block | Ceph RBD, Longhorn | ✓ | varies | – ² | ✓ |

¹ Some disks offer multi-attach for raw `volumeMode: Block` only (EBS io2
Multi-Attach, Azure shared disks), and then the application must coordinate
writes itself.
² Ceph RBD allows RWX only in `Block` mode. Longhorn provides RWX by serving
the volume over NFS.

### Where "Multi-Attach error" comes from

Cloud block disks are **attached** to a node, like plugging in a USB drive,
by the attach/detach controller in `kube-controller-manager`. An RWO disk can
be attached to only one node. If a pod that uses it is scheduled to a
**different** node while it is still attached elsewhere, the pod hangs in
`ContainerCreating` with:

```
Warning  FailedAttachVolume  attachdetach-controller
Multi-Attach error for volume "pvc-1234…" Volume is already used by pod(s) web-7d9c…
```

Typical causes:

* A **Deployment with an RWO PVC and the default `RollingUpdate`** strategy.
  The new pod starts before the old one stops, lands on another node, and
  can't attach the disk. The rollout is stuck. Fixes: `strategy: Recreate`,
  or a StatefulSet ([module 07](../07-statefulsets/README.md)).
* A **dead node**. The disk stays attached to it until Kubernetes is sure the
  node is gone. That means a forced detach after a timeout (6 minutes by
  default), or sooner if an admin applies the
  `node.kubernetes.io/out-of-service` taint.

In kind you get a *scheduling* error instead (`didn't match PersistentVolume's
node affinity`), because local-path volumes can't move at all (lab step 9).

For the full real-world version, **one RWO volume shared by two different
pods that must start in a specific order**, with four working patterns, see
[`../../scenarios/rwo-pvc-ordered-pods/README.md`](../../scenarios/rwo-pvc-ordered-pods/README.md).

### Lifecycle and reclaim policy

| PV phase | Meaning |
|---|---|
| `Available` | free, not bound to any claim |
| `Bound` | bound to exactly one PVC (`spec.claimRef`) |
| `Released` | its PVC was deleted, policy is `Retain`. Data is still there, but the PV keeps the old `claimRef`, so nothing new can bind until an admin edits it. |
| `Failed` | automatic reclamation (delete) failed; needs a human |

PVCs are `Pending` (no suitable PV yet), `Bound`, or `Lost` (the PV
disappeared underneath them).

`persistentVolumeReclaimPolicy` / StorageClass `reclaimPolicy`:

* **Delete** (the default for dynamically provisioned PVs): deleting the PVC
  deletes the PV *and the real disk*.
* **Retain** (the default for manually created PVs): the PV becomes
  `Released`, and the disk and data stay until someone cleans up.
* `Recycle` (`rm -rf` the volume) is deprecated. Don't use it.

**Protection finalizers.** Every PVC carries
`kubernetes.io/pvc-protection` and every PV carries
`kubernetes.io/pv-protection`. If you delete a PVC that a pod still uses, it
goes to `Terminating` and waits until no pod uses it. A bound PV likewise
waits for its PVC. This stops you from pulling the disk out from under a
running app.

### Volume expansion

If the StorageClass has `allowVolumeExpansion: true`, you can **grow** a PVC by
raising `spec.resources.requests.storage`. Shrinking is never supported.

```yaml
# a StorageClass that allows expansion (e.g. AWS EBS CSI)
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3-expandable
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
allowVolumeExpansion: true
volumeBindingMode: WaitForFirstConsumer
```

```bash
kubectl patch pvc data -p '{"spec":{"resources":{"requests":{"storage":"20Gi"}}}}'
kubectl get pvc data -o jsonpath='{.status.conditions}'   # Resizing → FileSystemResizePending → gone
```

The controller resizes the disk first. Then the kubelet grows the filesystem,
online for most CSI drivers. Some drivers need the pod restarted, which shows
up as the `FileSystemResizePending` condition. If an expansion fails (for
example because of quota), you can lower the request again, to a value still
above the original size, and retry. That is the
`RecoverVolumeExpansionFailure` feature, GA in the Kubernetes 1.37 this course
targets. Related: a **VolumeAttributesClass** (also GA in 1.37) lets you change
other properties of a live volume, such as IOPS or throughput, if the CSI
driver supports it.
**kind's local-path does not support expansion** (lab step 7 shows the
error).

### VolumeSnapshots (concept only)

CSI drivers that support snapshots let you take a point-in-time copy of a PVC
and create new PVCs from it. This needs the snapshot CRDs and the
snapshot-controller from
[kubernetes-csi/external-snapshotter](https://github.com/kubernetes-csi/external-snapshotter),
which managed clusters usually pre-install. kind's local-path has no snapshot
support, so this is for reading only:

```yaml
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata:
  name: csi-snapclass
driver: ebs.csi.aws.com            # your CSI driver
deletionPolicy: Delete
---
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: data-snap-1
  namespace: my-app
spec:
  volumeSnapshotClassName: csi-snapclass
  source:
    persistentVolumeClaimName: data     # snapshot this PVC
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: data-restored
  namespace: my-app
spec:
  dataSource:                           # new volume pre-filled from the snapshot
    apiGroup: snapshot.storage.k8s.io
    kind: VolumeSnapshot
    name: data-snap-1
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 20Gi
```

A snapshot is *crash-consistent*: it captures what the disk looks like if
power were cut at that instant. Databases should be flushed or frozen first,
or backed up with their own tools. Whole-namespace backup tools such as
Velero build on snapshots. `dataSource` can also point at another PVC
(`kind: PersistentVolumeClaim`) to **clone** it.

## Files

| File | What it demonstrates |
|---|---|
| [`00-namespace.yaml`](00-namespace.yaml) | the `lab-storage` namespace |
| [`01-emptydir.yaml`](01-emptydir.yaml) | two containers sharing an `emptyDir`; a `medium: Memory` tmpfs with `sizeLimit` |
| [`02-hostpath.yaml`](02-hostpath.yaml) | read-only `hostPath` of the node's `/var/log`, and why it's dangerous |
| [`03-static-pv.yaml`](03-static-pv.yaml) | a hand-made PV `lab-static-pv` (hostPath + node affinity, Retain, no class) |
| [`04-static-pvc.yaml`](04-static-pvc.yaml) | a PVC that binds to it with `storageClassName: ""` + `selector` |
| [`05-pod-static.yaml`](05-pod-static.yaml) | a pod using the static claim |
| [`06-dynamic-pvc.yaml`](06-dynamic-pvc.yaml) | a PVC using the default class: Pending until a consumer exists |
| [`07-pod-dynamic.yaml`](07-pod-dynamic.yaml) | the consumer; data that survives pod deletion |
| [`08-storageclass-retain.yaml`](08-storageclass-retain.yaml) | custom StorageClass `lab-retain` (Retain, WaitForFirstConsumer) |
| [`09-retain-demo.yaml`](09-retain-demo.yaml) | a claim + pod from `lab-retain` |
| [`10-rwo-same-node.yaml`](10-rwo-same-node.yaml) | two pods on the same node sharing one RWO claim |
| [`11-rwo-other-node.yaml`](11-rwo-other-node.yaml) | a pod on another node that can't use it |
| [`12-rwop.yaml`](12-rwop.yaml) | ReadWriteOncePod: second pod refused even on the same node |
| [`13-pv-failed-demo.yaml`](13-pv-failed-demo.yaml) | a PV that ends up `Failed` |
| [`solutions/`](solutions/) | reference answers for the exercises |

## Lab

```bash
cd modules/06-storage
kubectl apply -f 00-namespace.yaml
```

### 1. emptyDir: shared scratch space

```bash
kubectl apply -f 01-emptydir.yaml
kubectl wait -n lab-storage --for=condition=Ready pod/emptydir-demo
kubectl logs -n lab-storage emptydir-demo -c reader --tail=3
```

```
10:25:36 hello from the writer
10:25:41 hello from the writer
10:25:46 hello from the writer
```

The reader container prints what the writer container writes, because both
mount the same volume. Look at the two flavours:

```bash
kubectl exec -n lab-storage emptydir-demo -c writer -- df -h /shared /cache
```

```
Filesystem                Size      Used Available Use% Mounted on
/dev/vda                252.0G     31.5G      7.5G  81% /shared
tmpfs                    16.0M         0     16.0M   0% /cache
```

`/shared` is a directory on the node's disk. `/cache` is RAM, sized to its
`sizeLimit`. Try to overfill the tmpfs, and try to write through the reader's
read-only mount:

```bash
kubectl exec -n lab-storage emptydir-demo -c writer -- dd if=/dev/zero of=/cache/blob bs=1M count=20
kubectl exec -n lab-storage emptydir-demo -c writer -- rm /cache/blob
kubectl exec -n lab-storage emptydir-demo -c reader -- sh -c 'echo hack >> /shared/log.txt'
```

```
dd: error writing '/cache/blob': No space left on device
16777216 bytes (16.0MB) copied, ...
sh: can't create /shared/log.txt: Read-only file system
```

An emptyDir **survives container restarts**. Kill the writer's main process:

```bash
kubectl exec -n lab-storage emptydir-demo -c writer -- kill 1
kubectl get pod emptydir-demo -n lab-storage          # RESTARTS 1
kubectl exec -n lab-storage emptydir-demo -c writer -- head -2 /shared/log.txt
```

The old lines are still there. If you deleted the *pod*, they'd be gone.

### 2. hostPath: a window into the node

```bash
kubectl apply -f 02-hostpath.yaml
kubectl wait -n lab-storage --for=condition=Ready pod/hostpath-demo
kubectl logs -n lab-storage hostpath-demo
kubectl exec -n lab-storage hostpath-demo -- ls /host/var/log/pods | head -3
kubectl exec -n lab-storage hostpath-demo -- touch /host/var/log/x
```

```
alternatives.log
containers
pods
kube-system_kindnet-hpxkk_da04fd73-6651-44bf-b009-ca9100d37ad5
kube-system_kube-proxy-xfzzm_926c53c0-70f0-4c37-891f-be10fd3a97de
...
touch: /host/var/log/x: Read-only file system
```

This pod can read the logs of **every pod on the node**, from every
namespace. Mounted read-write, or with `path: /`, it could do far worse. Ask
Pod Security Admission what it thinks (a server-side dry run, so nothing
changes):

```bash
kubectl label ns lab-storage pod-security.kubernetes.io/enforce=baseline --dry-run=server --overwrite
```

```
Warning: existing pods in namespace "lab-storage" violate the new PodSecurity enforce level "baseline:latest"
Warning: hostpath-demo: hostPath volumes
```

### 3. Static provisioning

Create the PV. It's cluster-scoped, so it has no namespace:

```bash
kubectl apply -f 03-static-pv.yaml
kubectl get pv lab-static-pv
```

```
NAME            CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS      CLAIM   STORAGECLASS   ...
lab-static-pv   1Gi        RWO            Retain           Available
```

Claim it:

```bash
kubectl apply -f 04-static-pvc.yaml
kubectl get pvc static-claim -n lab-storage
kubectl get pv lab-static-pv
```

```
NAME           STATUS   VOLUME          CAPACITY   ACCESS MODES   STORAGECLASS   ...
static-claim   Bound    lab-static-pv   1Gi        RWO
NAME            CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS   CLAIM                      ...
lab-static-pv   1Gi        RWO            Retain           Bound    lab-storage/static-claim
```

The claim asked for 500Mi and got the **whole 1Gi**. A PV is never split.
It bound right away even though nothing uses it yet, because a PV with no
StorageClass has no `WaitForFirstConsumer` to wait for.

Use it:

```bash
kubectl apply -f 05-pod-static.yaml
kubectl wait -n lab-storage --for=condition=Ready pod/static-user
kubectl get pod static-user -n lab-storage -o wide     # NODE: kube-training-worker
kubectl logs -n lab-storage static-user
```

The pod landed on `kube-training-worker` because the PV's node affinity says
the data lives there. In kind, nodes are containers, so you can look at the
"disk" directly (use `podman exec` if you run kind on podman):

```bash
docker exec kube-training-worker cat /var/lab-static-pv/hello.txt
```

```
written at Thu Oct  8 10:26:10 UTC 2026 by static-user
```

### 4. Released, and back to Available

Delete the pod and the claim, then look at the PV:

```bash
kubectl delete -f 05-pod-static.yaml -f 04-static-pvc.yaml
kubectl get pv lab-static-pv
kubectl get pv lab-static-pv -o jsonpath='{.spec.claimRef}'; echo
```

```
NAME            CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS     CLAIM                      ...
lab-static-pv   1Gi        RWO            Retain           Released   lab-storage/static-claim
{"apiVersion":"v1","kind":"PersistentVolumeClaim","name":"static-claim","namespace":"lab-storage","resourceVersion":"11262","uid":"df40f368-..."}
```

`Released` still remembers the old claim, *including its UID*. Create the claim
again, with the same name:

```bash
kubectl apply -f 04-static-pvc.yaml
kubectl describe pvc static-claim -n lab-storage | tail -2
```

```
  Normal  FailedBinding  0s    persistentvolume-controller  no persistent volumes available for this claim and no storage class is set
```

It stays Pending. The new PVC has a new UID, and Kubernetes won't hand
someone else's data to a new claim without an admin deciding to. Make the
decision by removing the stale `claimRef`:

```bash
kubectl patch pv lab-static-pv --type json -p '[{"op":"remove","path":"/spec/claimRef"}]'
kubectl get pv lab-static-pv          # Available, then Bound within ~15s (the PV controller's resync)
kubectl apply -f 05-pod-static.yaml
kubectl wait -n lab-storage --for=condition=Ready pod/static-user
kubectl logs -n lab-storage static-user
```

```
written at Thu Oct  8 10:26:10 UTC 2026 by static-user
written at Thu Oct  8 10:26:31 UTC 2026 by static-user
```

The first line was written before you deleted the claim.

### 5. Dynamic provisioning and WaitForFirstConsumer

```bash
kubectl get storageclass
kubectl apply -f 06-dynamic-pvc.yaml
kubectl get pvc data -n lab-storage
kubectl describe pvc data -n lab-storage | tail -2
```

```
NAME                 PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE      ALLOWVOLUMEEXPANSION
standard (default)   rancher.io/local-path   Delete          WaitForFirstConsumer   false

NAME   STATUS    VOLUME   CAPACITY   ACCESS MODES   STORAGECLASS   ...
data   Pending                                      standard

  Normal  WaitForFirstConsumer  0s    persistentvolume-controller  waiting for first consumer to be created before binding
```

`Pending` is expected here. Now create the first consumer:

```bash
kubectl apply -f 07-pod-dynamic.yaml
kubectl wait -n lab-storage --for=condition=Ready pod/writer
kubectl get pvc data -n lab-storage
kubectl get pvc data -n lab-storage -o jsonpath='{.metadata.annotations.volume\.kubernetes\.io/selected-node}'; echo
```

```
NAME   STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS
data   Bound    pvc-0dc8c4d7-8c6c-4122-91f5-55e33506c895   200Mi      RWO            standard
kube-training-worker2
```

The scheduler picked a node and wrote it on the PVC. The provisioner then
created a PV **pinned to that node**:

```bash
kubectl get pv -o yaml | grep -A8 nodeAffinity
```

```
    nodeAffinity:
      required:
        nodeSelectorTerms:
        - matchExpressions:
          - key: kubernetes.io/hostname
            operator: In
            values:
            - kube-training-worker2
```

(You'll see one block per PV, including `lab-static-pv`. Add
`kubectl get pv $(kubectl get pvc data -n lab-storage -o jsonpath='{.spec.volumeName}') -o yaml`
to look at just this one.) From now on, every pod that uses `data` will be
scheduled onto `kube-training-worker2`. If that node died, the pod could not
run anywhere. That is the price of node-local storage.

### 6. Data outlives the pod

```bash
kubectl delete pod writer -n lab-storage
kubectl apply -f 07-pod-dynamic.yaml
kubectl wait -n lab-storage --for=condition=Ready pod/writer
kubectl logs -n lab-storage writer
```

```
10:26:47 pod-uid=b22fdbcd-f186-4427-96c4-cd2900c3c1f9 node=kube-training-worker2
10:26:58 pod-uid=c75a49bf-b482-4a45-a270-9f66c2a2d8dd node=kube-training-worker2
```

Different pod UIDs, same data. Repeat it as often as you like.

### 7. Try to expand

```bash
kubectl patch pvc data -n lab-storage -p '{"spec":{"resources":{"requests":{"storage":"1Gi"}}}}'
```

```
Error from server (Forbidden): persistentvolumeclaims "data" is forbidden: only dynamically provisioned pvc can be resized and the storageclass that provisions the pvc must support resize
```

`standard` has `allowVolumeExpansion: false`. The admission plugin rejects the
change before anything else happens (see [Volume expansion](#volume-expansion)).

### 8. A custom StorageClass with Retain

```bash
kubectl apply -f 08-storageclass-retain.yaml
kubectl apply -f 09-retain-demo.yaml
kubectl wait -n lab-storage --for=condition=Ready pod/retain-user
PV=$(kubectl get pvc precious -n lab-storage -o jsonpath='{.spec.volumeName}')
NODE=$(kubectl get pod retain-user -n lab-storage -o jsonpath='{.spec.nodeName}')
DIR=$(kubectl get pv $PV -o jsonpath='{.spec.hostPath.path}')
echo "$PV on $NODE at $DIR"

kubectl delete -f 09-retain-demo.yaml
kubectl get pv $PV
docker exec $NODE cat $DIR/important.txt
```

```
pvc-33028e00-659e-46a0-bc25-5b864d3a90e9 on kube-training-worker2 at /var/local-path-provisioner/pvc-33028e00-..._lab-storage_precious
persistentvolumeclaim "precious" deleted from lab-storage namespace
pod "retain-user" deleted from lab-storage namespace
NAME                                       CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS     CLAIM                  STORAGECLASS
pvc-33028e00-659e-46a0-bc25-5b864d3a90e9   100Mi      RWO            Retain           Released   lab-storage/precious   lab-retain
very important data
```

The claim is gone, but the PV and the data are not. Compare with what step 11
does to `data`, whose class uses `Delete`. **Even deleting the Released PV
does not remove the data**: `Retain` means the storage is now yours to clean
up. Keep the PV for exercise 6. The Cleanup section removes it.

### 9. RWO is per node: two pods, one volume

```bash
kubectl apply -f 10-rwo-same-node.yaml
kubectl wait -n lab-storage --for=condition=Ready pod/rwo-a pod/rwo-b
kubectl get pods -n lab-storage -l app=rwo-demo -o wide
kubectl exec -n lab-storage rwo-a -- tail -6 /data/shared.log
```

```
NAME    READY   STATUS    RESTARTS   AGE   IP             NODE
rwo-a   1/1     Running   0          6s    10.244.2.120   kube-training-worker
rwo-b   1/1     Running   0          6s    10.244.2.119   kube-training-worker
10:27:37 rwo-a
10:27:37 rwo-b
10:27:42 rwo-a
10:27:42 rwo-b
10:27:47 rwo-b
10:27:47 rwo-a
```

Both pods are writing to one `ReadWriteOnce` volume at the same time. That's
allowed because they're on the same **node**. Now try from the other worker:

```bash
kubectl apply -f 11-rwo-other-node.yaml
kubectl get pod rwo-c -n lab-storage
kubectl get events -n lab-storage --field-selector involvedObject.name=rwo-c,reason=FailedScheduling
```

```
NAME    READY   STATUS    RESTARTS   AGE
rwo-c   0/1     Pending   0          0s
... 0/3 nodes are available: 1 node(s) didn't match PersistentVolume's node affinity,
    1 node(s) didn't match Pod's node affinity/selector, 1 node(s) had untolerated taint(s).
    preemption: 0/3 nodes are available: 3 Preemption is not helpful for scheduling.
```

On kind the scheduler refuses because the data physically lives on the other
node. On a cloud cluster with an RWO block disk, this is where you'd get
the **Multi-Attach error** described in [Concepts](#where-multi-attach-error-comes-from).
Running two pods in a controlled order on one RWO volume is a whole topic of
its own: see
[`../../scenarios/rwo-pvc-ordered-pods/README.md`](../../scenarios/rwo-pvc-ordered-pods/README.md).

```bash
kubectl delete pod rwo-c -n lab-storage
```

### 10. RWOP is per pod

```bash
kubectl apply -f 12-rwop.yaml
kubectl get pods -n lab-storage -l app=rwop-demo -o wide
kubectl get events -n lab-storage --field-selector involvedObject.name=rwop-b,reason=FailedScheduling
```

```
NAME     READY   STATUS    RESTARTS   AGE   IP             NODE
rwop-a   1/1     Running   0          7s    10.244.2.125   kube-training-worker
rwop-b   0/1     Pending   0          7s    <none>         <none>
... 0/3 nodes are available: 1 node(s) didn't match Pod's node affinity/selector,
    1 node(s) had untolerated taint(s), 1 node(s) unavailable due to PersistentVolumeClaim
    with ReadWriteOncePod access mode already in-use by another pod. ...
```

Same node, and still refused. (Whichever pod the scheduler handles first
wins, almost always `rwop-a`.) Release the volume and the waiting pod gets it:

```bash
kubectl delete pod rwop-a -n lab-storage
kubectl wait -n lab-storage --for=condition=Ready pod/rwop-b
```

### 11. Protection finalizer: you can't pull a disk out from under a pod

`writer` is still using `data`:

```bash
kubectl get pvc data -n lab-storage -o jsonpath='{.metadata.finalizers}'; echo
kubectl delete pvc data -n lab-storage --wait=false
kubectl get pvc data -n lab-storage
kubectl describe pvc data -n lab-storage | grep -E '^(Status|Finalizers|Used By)'
```

```
["kubernetes.io/pvc-protection"]
persistentvolumeclaim "data" deleted from lab-storage namespace
NAME   STATUS        VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS
data   Terminating   pvc-0dc8c4d7-8c6c-4122-91f5-55e33506c895   200Mi      RWO            standard
Status:        Terminating (lasts 1s)
Finalizers:    [kubernetes.io/pvc-protection]
Used By:       writer
```

"Deleted" really means "marked for deletion". The finalizer holds the PVC
until its last user is gone:

```bash
kubectl delete pod writer -n lab-storage
kubectl get pvc data -n lab-storage     # NotFound
kubectl get pv | grep lab-storage/data  # gone a few seconds later: class standard uses reclaimPolicy Delete
```

### 12. A Failed PV

```bash
kubectl apply -f 13-pv-failed-demo.yaml
kubectl get pv lab-failed-pv            # Bound to lab-storage/doomed
kubectl delete pvc doomed -n lab-storage
kubectl get pv lab-failed-pv
kubectl get events -A --field-selector involvedObject.name=lab-failed-pv
```

```
NAME            CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS   CLAIM                ...
lab-failed-pv   100Mi      RWO            Delete           Failed   lab-storage/doomed
... Warning   VolumeFailedDelete   persistentvolume/lab-failed-pv   host_path deleter only supports /tmp/.+ but received provided /var/lab-failed-pv
```

The policy said `Delete`, but nothing could delete this kind of volume, so the
PV is parked in `Failed` for a human. You've now seen every PV phase:
Available, Bound, Released, Failed.

## Exercises

1. **Find the emptyDir on the node.** Where does `emptydir-demo`'s `shared`
   volume live on the node's disk? Delete the pod and check that the
   `volumes/` directory disappears (the rest of the pod's directory is
   garbage-collected by the kubelet a little later).
   *Hint:* `kubectl get pod emptydir-demo -n lab-storage -o jsonpath='{.metadata.uid}'`, then
   `docker exec <node> ls /var/lib/kubelet/pods/<uid>/volumes/kubernetes.io~empty-dir/`.

2. **Immediate binding vs node-local storage.** Create a StorageClass
   `lab-immediate` (local-path, `volumeBindingMode: Immediate`) and a PVC that
   uses it. What happens, and why does `WaitForFirstConsumer` exist?
   *Hint:* `kubectl describe pvc`. Solution:
   [`solutions/02-immediate-storageclass.yaml`](solutions/02-immediate-storageclass.yaml)
   (`configuration error, no node was specified`).

3. **A Deployment that owns an RWO volume.** Write a one-replica Deployment
   that writes to a PVC, so that a rollout can never need the volume on two
   nodes at once. Prove it with `kubectl rollout restart` and watch the pods.
   *Hint:* `spec.strategy`. Solution:
   [`solutions/03-deployment-rwo-recreate.yaml`](solutions/03-deployment-rwo-recreate.yaml).
   For multi-pod and ordered variants, see the
   [RWO scenario](../../scenarios/rwo-pvc-ordered-pods/README.md).

4. **Reserve a PV.** Create a PV `lab-reserved-pv` that only the PVC
   `lab-storage/reserved` may bind to, and that claim.
   *Hint:* `PV.spec.claimRef` + `PVC.spec.volumeName`. Solution:
   [`solutions/04-reserved-pv.yaml`](solutions/04-reserved-pv.yaml).

5. **Overfill an emptyDir.** In one pod, write 20M into a 16Mi
   `medium: Memory` emptyDir and 60M into a 50Mi disk emptyDir. Predict, then
   observe, what happens in each case.
   *Hint:* one is a filesystem size, the other is a kubelet eviction
   threshold. Solution:
   [`solutions/05-emptydir-limits.yaml`](solutions/05-emptydir-limits.yaml)
   (tmpfs: `No space left on device`. Disk: the pod is **Evicted** with
   `Usage of EmptyDir volume "disk" exceeds the limit "50Mi"` about 30 seconds
   later).

6. **Rescue Released data.** The `lab-retain` PV from step 8 is `Released`.
   Bind it to a new claim called `restored` and read `important.txt` from a
   new pod.
   *Hint:* the stale `claimRef` must go, and the new claim must match the PV's
   class, access mode and size. Solution:
   [`solutions/06-restore-claim.yaml`](solutions/06-restore-claim.yaml).

## Cleanup

The namespace holds the PVCs and pods. PVs and StorageClasses are
cluster-scoped and need their own commands.

```bash
kubectl delete namespace lab-storage

# Hand-made PVs (Retain, or Failed) are not deleted with the namespace:
kubectl delete pv lab-static-pv lab-failed-pv lab-reserved-pv --ignore-not-found

# PVs from the lab-retain class: delete their data on the node, then the PV.
for pv in $(kubectl get pv -o jsonpath='{range .items[?(@.spec.storageClassName=="lab-retain")]}{.metadata.name}{" "}{end}'); do
  node=$(kubectl get pv "$pv" -o jsonpath='{.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]}')
  dir=$(kubectl get pv "$pv" -o jsonpath='{.spec.hostPath.path}')
  docker exec "$node" rm -rf "$dir"
  kubectl delete pv "$pv"
done

kubectl delete storageclass lab-retain lab-immediate --ignore-not-found

# Directories the hostPath PVs created on the nodes:
docker exec kube-training-worker  rm -rf /var/lab-static-pv
docker exec kube-training-worker2 rm -rf /var/lab-reserved-pv
```

PVs from the `standard` class are deleted automatically (reclaim policy
`Delete`) once their PVCs are gone. Check with `kubectl get pv`.

## Further reading

* [Volumes](https://kubernetes.io/docs/concepts/storage/volumes/) (emptyDir, hostPath, local …)
* [Persistent Volumes](https://kubernetes.io/docs/concepts/storage/persistent-volumes/): binding, access modes, reclaiming, expansion
* [Storage Classes](https://kubernetes.io/docs/concepts/storage/storage-classes/)
* [Dynamic volume provisioning](https://kubernetes.io/docs/concepts/storage/dynamic-provisioning/)
* [Volume snapshots](https://kubernetes.io/docs/concepts/storage/volume-snapshots/) and [CSI volume cloning](https://kubernetes.io/docs/concepts/storage/volume-pvc-datasource/)
* [Configure a Pod to use a PersistentVolume](https://kubernetes.io/docs/tasks/configure-pod-container/configure-persistent-volume-storage/)
* [Non-graceful node shutdown](https://kubernetes.io/docs/concepts/cluster-administration/node-shutdown/#non-graceful-node-shutdown) (the `out-of-service` taint)
* [rancher/local-path-provisioner](https://github.com/rancher/local-path-provisioner), kind's default provisioner
