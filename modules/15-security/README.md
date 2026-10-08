# Module 15 - Security

## Goal

Run workloads with the least privilege they need, and make the cluster
*refuse* workloads that ask for more.

## What you'll learn

* What a container can do by default, and how to see it (`id`, `/proc/1/status`)
* `securityContext` at pod and container level: `runAsUser`/`runAsGroup`/`fsGroup`,
  `runAsNonRoot`, `readOnlyRootFilesystem`, `allowPrivilegeEscalation`,
  capabilities, seccomp
* Why `capabilities.add` does nothing for non-root processes
* Pod Security Admission (PSA): the `privileged` / `baseline` / `restricted`
  levels and the `enforce` / `warn` / `audit` modes
* Running `nginx:1.27-alpine` as non-root with a read-only root filesystem
* Turning off ServiceAccount token automounting
* Image tags vs digests, and what `imagePullPolicy` really does
* Writing your own admission rules with **ValidatingAdmissionPolicy** and CEL
* Secrets hygiene, and a hardening checklist you can reuse

## Concepts

### Layers of defence

```
 image            minimal base, pinned by digest, scanned, signed
   |
 pod spec         securityContext: non-root, no privilege escalation, no caps,
   |              read-only root FS, seccomp; no token unless needed
   |
 admission        Pod Security Admission (built in, per namespace)
   |              ValidatingAdmissionPolicy (built in, your own CEL rules)
   |              Gatekeeper / Kyverno (add-ons, richer policy)
   |
 API access       RBAC (module 11), Secrets encryption at rest
 network          NetworkPolicies (module 13)
 node/runtime     seccomp, AppArmor/SELinux, user namespaces, sandboxed runtimes
```

No single layer is enough. The pod spec layer is the one *you* control as an
app developer; admission is how the platform team makes sure everyone does it.

### securityContext: pod level vs container level

`spec.securityContext` sets defaults for every container plus pod-wide
settings; `spec.containers[].securityContext` overrides per container.

| Field | Level | What it does | Required by `restricted`? |
|---|---|---|---|
| `runAsUser` / `runAsGroup` | both | uid / primary gid of the process (otherwise the image decides, usually 0) | no (but needed if the image runs as root) |
| `runAsNonRoot: true` | both | kubelet refuses to start a container whose uid would be 0 | **yes** |
| `fsGroup` | pod | extra gid for all processes; supported volumes are chgrp'ed to it and made group-writable | no |
| `fsGroupChangePolicy` | pod | `OnRootMismatch` skips the recursive chown when it is already right (fast startup) | no |
| `supplementalGroups` | pod | extra gids | no |
| `seccompProfile` | both | syscall filter; `RuntimeDefault` = the runtime's sane default | **yes** (`RuntimeDefault` or `Localhost`) |
| `allowPrivilegeEscalation: false` | container | sets `no_new_privs`: setuid binaries / file caps can't raise privileges | **yes** |
| `capabilities.drop` / `add` | container | remove / add Linux capabilities | **yes**: drop `ALL`, add only `NET_BIND_SERVICE` |
| `readOnlyRootFilesystem: true` | container | image filesystem is read-only; use `emptyDir` for scratch space | no (do it anyway) |
| `privileged: true` | container | everything: all caps, all devices, no seccomp. Almost never needed by apps | forbidden (already by `baseline`) |
| `appArmorProfile` / `seLinuxOptions` | both | LSM confinement (node must support it) | restricted limits the values |

### Linux capabilities in 60 seconds

Root's powers are split into ~40 *capabilities*. Container runtimes give root
in a container a reduced default set (14 of them in containerd:
`CHOWN, DAC_OVERRIDE, FSETID, FOWNER, MKNOD, NET_RAW, SETGID, SETUID, SETFCAP,
SETPCAP, NET_BIND_SERVICE, SYS_CHROOT, KILL, AUDIT_WRITE`). You see them as a
hex bitmask in `/proc/<pid>/status`:

| Mask (CapEff) | Meaning |
|---|---|
| `00000000a80425fb` | containerd's default set (the 14 above) |
| `0000000000000400` | only bit 10 = `CAP_NET_BIND_SERVICE` |
| `0000000000000000` | nothing |

(Decode any mask on a Linux machine with `capsh --decode=<mask>`.)

**Gotcha:** `capabilities.add` only becomes *effective* for processes running
as **root** (or binaries with file capabilities set via `setcap`). For a
non-root process the added capability lands in the *bounding* set only,
because Kubernetes has no way to set *ambient* capabilities. So "non-root +
add `NET_BIND_SERVICE`" does **not** let a process bind port 80. The portable
answer is to listen on a port >= 1024 and let the Service map 80 to it.
(On containerd >= 2.0 and CRI-O, pods get `net.ipv4.ip_unprivileged_port_start=0`,
so any user can bind low ports anyway - but don't build on that.)

### Pod Security Standards and Pod Security Admission

The **Pod Security Standards** are three fixed levels:

| Level | Meant for | Blocks (highlights) |
|---|---|---|
| `privileged` | system components, CNI, storage drivers | nothing |
| `baseline` | most apps, minimal friction | `privileged`, host namespaces (`hostPID`, `hostNetwork`, `hostIPC`), `hostPath`, `hostPort`, adding dangerous caps (e.g. `SYS_ADMIN`, `NET_ADMIN`), unsafe sysctls, `/proc` unmasking |
| `restricted` | security-sensitive apps, multi-tenant clusters | everything baseline blocks + must run as non-root, drop ALL caps, `allowPrivilegeEscalation: false`, seccomp `RuntimeDefault`/`Localhost`, only safe volume types |

**Pod Security Admission** is the built-in admission controller that applies
them, configured with namespace labels:

```
pod-security.kubernetes.io/<MODE>: <LEVEL>
pod-security.kubernetes.io/<MODE>-version: v1.33     # or "latest"
```

| Mode | Effect | Checks |
|---|---|---|
| `enforce` | reject violating pods | Pods only |
| `warn` | return a warning to the client | Pods **and** workload templates (Deployment, Job, ...) |
| `audit` | annotate the audit log event | Pods and workload templates |

`enforce` checking only Pods means a bad Deployment is *accepted* and then
silently fails to create pods - you will see this in the lab. Always pair
`enforce` with `warn`. An unlabelled namespace is effectively `privileged`
(unless the cluster admin set different defaults in the API server's
`AdmissionConfiguration`, which is also where exemptions live).

> History: PodSecurityPolicy (PSP) was removed in Kubernetes 1.25; PSA replaced it.

### Images: tags, digests and pull policy

* A **tag** (`nginx:1.27-alpine`) is a movable pointer. A **digest**
  (`nginx@sha256:...`) is the hash of the content and can never change.
  `name:tag@sha256:...` is allowed: the tag is just a human-readable hint.
* `imagePullPolicy` defaults to `Always` for `:latest` or no tag and to
  `IfNotPresent` otherwise. `Always` does not re-download layers; it asks the
  registry which digest the tag points to *right now*. In multi-tenant
  clusters, `Always` (or the `AlwaysPullImages` admission plugin) stops a pod
  from using a private image that someone else's pod already pulled to the node.
* Tools like Renovate/Dependabot can keep digests up to date automatically.

### ServiceAccount tokens

Every pod gets a short-lived, auto-rotated token, bound to that pod, for its
ServiceAccount, mounted at `/var/run/secrets/kubernetes.io/serviceaccount/`.
Most apps never call the Kubernetes API, so the token is pure risk. Turn it off
with `automountServiceAccountToken: false` on the ServiceAccount (default for
its pods) or on the pod (wins over the ServiceAccount).

### ValidatingAdmissionPolicy (VAP)

GA since Kubernetes 1.30. You write rules in **CEL** (Common Expression
Language); the API server evaluates them in-process. No webhook service,
no certificates, no network hop that can fail.

```
ValidatingAdmissionPolicy          ValidatingAdmissionPolicyBinding
  matchConstraints  (which kinds)    policyName
  variables         (helpers)        matchResources (which namespaces/objects)
  validations       (CEL -> bool)    validationActions: [Deny] | [Warn, Audit] | ...
  messageExpression (nice errors)    paramRef (optional: per-binding parameters)
```

Inside CEL, `object` is the incoming object (`oldObject` on UPDATE),
`request` has the user and operation, `namespaceObject` the namespace, and
`params` the optional parameter resource. Both objects are cluster-scoped.

Its sibling **MutatingAdmissionPolicy** (CEL-based mutation) is alpha in 1.33
and beta in 1.34 - not covered here.

### Beyond the built-ins (concepts only)

* **OPA Gatekeeper** - policies in Rego, delivered as `ConstraintTemplate` +
  `Constraint` CRDs; mature, with an audit mode that reports existing violations.
* **Kyverno** - policies as Kubernetes YAML; can validate, *mutate* (e.g. add
  default securityContexts), *generate* objects (e.g. a default NetworkPolicy
  per namespace) and verify image signatures.
* **Image signing and provenance** - sign images in CI with Sigstore
  **cosign** (keyless signing ties the signature to your CI identity, recorded
  in a public transparency log), attach SBOMs/attestations, and verify at
  admission time with Kyverno `verifyImages`, the Sigstore
  `policy-controller`, or Ratify + Gatekeeper. Combine with vulnerability
  scanning (Trivy, Grype) in CI.
* **Node/runtime hardening** - user namespaces (`spec.hostUsers: false`, beta
  and on by default in 1.33: root in the pod is an unprivileged uid on the
  node), AppArmor/SELinux profiles, sandboxed runtimes via `RuntimeClass`
  (gVisor, Kata Containers).

### Hardening checklist

Copy this into your team's review template.

**Pod spec**
- [ ] `runAsNonRoot: true` and an explicit numeric `runAsUser`/`runAsGroup` when the image defaults to root
- [ ] `allowPrivilegeEscalation: false`
- [ ] `capabilities.drop: ["ALL"]`, add back only what is proven necessary
- [ ] `seccompProfile.type: RuntimeDefault`
- [ ] `readOnlyRootFilesystem: true` + `emptyDir` for `/tmp` and cache/pid dirs
- [ ] no `privileged`, `hostPID`, `hostNetwork`, `hostIPC`, `hostPath`, `hostPort`
- [ ] app listens on a port >= 1024
- [ ] requests (cpu, memory) and a memory limit on every container
- [ ] own ServiceAccount per app, `automountServiceAccountToken: false` unless it calls the API

**Images**
- [ ] pinned version tag, ideally plus digest; never `:latest`
- [ ] minimal base (distroless/alpine/scratch), scanned in CI, signed

**Namespace / cluster**
- [ ] every namespace has PSA labels (`enforce` + `warn`), `restricted` wherever possible
- [ ] admission policies (VAP / Kyverno / Gatekeeper) for org rules: allowed registries, no `:latest`, resources, labels
- [ ] RBAC least privilege; nobody but the app can `get`/`list` its Secrets
- [ ] default-deny NetworkPolicies (module 13)
- [ ] Secrets encrypted at rest; real secret values never committed to git

## Files

| File | Namespace | What it demonstrates |
|---|---|---|
| [`00-namespace.yaml`](00-namespace.yaml) | - | `lab-security` (enforce baseline, warn/audit restricted) and `lab-security-restricted` (enforce restricted) |
| [`01-pod-root.yaml`](01-pod-root.yaml) | lab-security | The defaults: root, 14 capabilities, no seccomp, writable FS |
| [`02-pod-hardened.yaml`](02-pod-hardened.yaml) | lab-security | Pod- and container-level securityContext, fsGroup, read-only root FS + emptyDir |
| [`03-capabilities.yaml`](03-capabilities.yaml) | lab-security | Root with default caps vs root with `drop: [ALL]`, `add: [NET_BIND_SERVICE]` |
| [`04-nginx-nonroot-config.yaml`](04-nginx-nonroot-config.yaml) | lab-security-restricted | nginx server block on port 8080 |
| [`05-nginx-nonroot.yaml`](05-nginx-nonroot.yaml) | lab-security-restricted | nginx as uid 101, read-only root FS, passes `restricted` |
| [`06-serviceaccount-no-automount.yaml`](06-serviceaccount-no-automount.yaml) | lab-security | ServiceAccount with token automount off |
| [`07-image-digest.yaml`](07-image-digest.yaml) | lab-security | Image pinned by digest, explicit `imagePullPolicy` |
| [`08-secret-hygiene.yaml`](08-secret-hygiene.yaml) | lab-security | Immutable Secret mounted read-only as files, mode 0440 |
| [`09-vap-deny-latest.yaml`](09-vap-deny-latest.yaml) | cluster | VAP + binding: images must have a tag (not `latest`) or a digest |
| [`10-vap-require-resources.yaml`](10-vap-require-resources.yaml) | cluster | VAP + binding: cpu/memory requests and a memory limit required |
| [`psa/01-privileged-pod.yaml`](psa/01-privileged-pod.yaml) | lab-security-restricted | **Rejected**: privileged + host namespaces + hostPath |
| [`psa/02-root-pod.yaml`](psa/02-root-pod.yaml) | lab-security-restricted | **Rejected**: an innocent-looking pod that doesn't prove it is safe |
| [`psa/03-noncompliant-deployment.yaml`](psa/03-noncompliant-deployment.yaml) | lab-security-restricted | Deployment **accepted**, its pods **rejected** |
| [`psa/04-compliant-pod.yaml`](psa/04-compliant-pod.yaml) | lab-security-restricted | **Admitted**: the minimum restricted pod |
| [`vap/01-latest-tag-pod.yaml`](vap/01-latest-tag-pod.yaml) | lab-security | **Denied** by policy 09 |
| [`vap/02-untagged-deployment.yaml`](vap/02-untagged-deployment.yaml) | lab-security | **Denied** by policy 09 (untagged init container) |
| [`vap/03-no-limits-pod.yaml`](vap/03-no-limits-pod.yaml) | lab-security | **Denied** by policy 10 |
| [`solutions/`](solutions/) | | Exercise solutions |

`kubectl apply -f modules/15-security/` applies only the numbered top-level
files (all of which are admitted). The `psa/` and `vap/` folders contain
manifests that are **meant to fail**, so apply them one by one.

## Lab

All commands are run from the repo root.

### 1. Create the namespaces

```bash
kubectl apply -f modules/15-security/00-namespace.yaml
kubectl get ns lab-security lab-security-restricted --show-labels
```

```
NAME                      STATUS   AGE   LABELS
lab-security              Active   5s    app=security,kubernetes.io/metadata.name=lab-security,pod-security.kubernetes.io/audit-version=v1.33,pod-security.kubernetes.io/audit=restricted,pod-security.kubernetes.io/enforce-version=v1.33,pod-security.kubernetes.io/enforce=baseline,...
lab-security-restricted   Active   5s    app=security,...,pod-security.kubernetes.io/enforce=restricted,...
```

### 2. The "before" picture: what a default pod can do

```bash
kubectl apply -f modules/15-security/01-pod-root.yaml
```

Because `lab-security` *warns* at the `restricted` level, kubectl prints
exactly what is wrong with this pod (it is still admitted - enforce is only
`baseline`):

```
Warning: would violate PodSecurity "restricted:v1.33": allowPrivilegeEscalation != false (container "app" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "app" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "app" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "app" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
pod/as-root created
```

Look inside:

```bash
kubectl -n lab-security exec as-root -- id
kubectl -n lab-security exec as-root -- grep -E '^(CapEff|NoNewPrivs|Seccomp):' /proc/1/status
kubectl -n lab-security exec as-root -- ls /var/run/secrets/kubernetes.io/serviceaccount
```

```
uid=0(root) gid=0(root) groups=0(root),10(wheel)
CapEff:	00000000a80425fb
NoNewPrivs:	0
Seccomp:	0
ca.crt
namespace
token
```

Root, the runtime's 14 default capabilities, privilege escalation possible,
**no seccomp filter at all** (`Seccomp: 0` = disabled; the kubelet defaults
to `Unconfined`), and an API token it will never use.

### 3. The "after" picture: a hardened pod

```bash
kubectl apply -f modules/15-security/02-pod-hardened.yaml      # note: no warning
kubectl -n lab-security exec hardened -c app -- id
kubectl -n lab-security exec hardened -c override -- id
```

```
uid=1000 gid=3000 groups=2000,3000
uid=1001 gid=3000 groups=2000,3000
```

`runAsUser: 1000` and `runAsGroup: 3000` come from the pod level; `fsGroup:
2000` appears as a supplementary group. The `override` container sets its
own `runAsUser: 1001` - container level wins - but still inherits the
pod-level group settings.

```bash
kubectl -n lab-security exec hardened -c app -- grep -E '^(CapEff|CapBnd|NoNewPrivs|Seccomp):' /proc/1/status
```

```
CapEff:	0000000000000000
CapBnd:	0000000000000400
NoNewPrivs:	1
Seccomp:	2
```

* `CapEff: 0` - no effective capabilities. `NET_BIND_SERVICE` was "added" but
  only shows up in the bounding set (`CapBnd: 0x400`), because the process is
  not root (see Concepts).
* `NoNewPrivs: 1` - that is `allowPrivilegeEscalation: false`.
* `Seccomp: 2` - filter mode, i.e. `RuntimeDefault` is active.

The read-only root filesystem and the writable volumes:

```bash
kubectl -n lab-security exec hardened -c app -- touch /evil
kubectl -n lab-security exec hardened -c app -- touch /tmp/ok /data/ok
kubectl -n lab-security exec hardened -c override -- touch /data/from-1001
kubectl -n lab-security exec hardened -c app -- ls -ln /data
kubectl -n lab-security exec hardened -c app -- ls -ldn /data
```

```
touch: /evil: Read-only file system
command terminated with exit code 1
total 0
-rw-r--r--    1 1001     2000             0 Oct  8 10:14 from-1001
-rw-r--r--    1 1000     2000             0 Oct  8 10:14 ok
drwxrwsrwx    2 0        2000          4096 Oct  8 10:14 /data
```

The `/data` emptyDir is group `2000` with the setgid bit (`s`), so files
created by *any* container land in group 2000 and can be shared. That is
what `fsGroup` is for.

### 4. Capabilities: root without its superpowers

```bash
kubectl apply -f modules/15-security/03-capabilities.yaml
kubectl -n lab-security logs caps-default
kubectl -n lab-security logs caps-dropped
```

```
id:                uid=0(root) gid=0(root) groups=0(root),10(wheel)
CapEff:            00000000a80425fb
unpriv port start: 0
chown:             OK
bind port 80:      OK
```
```
id:                uid=0(root) gid=0(root) groups=0(root),10(wheel)
CapEff:            0000000000000400
unpriv port start: 0
chown: /tmp/f: Operation not permitted
chown:             FAILED
bind port 80:      OK
```

Both are uid 0, but `caps-dropped` can't `chown` - "root" is just a uid;
the power comes from capabilities. Port 80 works in both: in
`caps-dropped` because `NET_BIND_SERVICE` was added back, and in general
because containerd sets `ip_unprivileged_port_start=0` (printed above).

### 5. Pod Security Admission in action

Apply the four demo manifests to the `restricted` namespace one at a time:

```bash
kubectl apply -f modules/15-security/psa/01-privileged-pod.yaml
```

```
Error from server (Forbidden): error when creating "modules/15-security/psa/01-privileged-pod.yaml": pods "privileged" is forbidden: violates PodSecurity "restricted:v1.33": host namespaces (hostNetwork=true, hostPID=true), privileged (container "shell" must not set securityContext.privileged=true), allowPrivilegeEscalation != false (...), unrestricted capabilities (...), restricted volume types (volume "host-root" uses restricted volume type "hostPath"), runAsNonRoot != true (...), seccompProfile (...)
```

```bash
kubectl apply -f modules/15-security/psa/02-root-pod.yaml
```

```
Error from server (Forbidden): error when creating "modules/15-security/psa/02-root-pod.yaml": pods "root-pod" is forbidden: violates PodSecurity "restricted:v1.33": allowPrivilegeEscalation != false (container "app" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "app" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "app" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "app" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
```

The same pod as `01-pod-root.yaml` - fine under `baseline`, rejected under
`restricted` because it doesn't *opt in* to the safe settings.

Now the surprise:

```bash
kubectl apply -f modules/15-security/psa/03-noncompliant-deployment.yaml
kubectl -n lab-security-restricted get deploy,rs,pods -l app=sneaky
kubectl -n lab-security-restricted get events --field-selector reason=FailedCreate | head -3
```

```
Warning: would violate PodSecurity "restricted:v1.33": allowPrivilegeEscalation != false (...), ...
deployment.apps/sneaky created

NAME                     READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/sneaky   0/1     0            0           3s

NAME                                DESIRED   CURRENT   READY   AGE
replicaset.apps/sneaky-574bf48765   1         0         0       3s

LAST SEEN   TYPE      REASON         OBJECT                         MESSAGE
4s          Warning   FailedCreate   replicaset/sneaky-574bf48765   Error creating: pods "sneaky-574bf48765-v2pbc" is forbidden: violates PodSecurity "restricted:v1.33": ...
```

The Deployment was stored (only a *warning*), but every pod its ReplicaSet
tries to create is rejected. No pods means no pod events - the errors are on
the **ReplicaSet**. Remember this when "my Deployment has no pods".

Finally, a compliant pod:

```bash
kubectl apply -f modules/15-security/psa/04-compliant-pod.yaml
kubectl -n lab-security-restricted logs compliant
kubectl -n lab-security-restricted delete deployment sneaky
```

```
pod/compliant created
uid=65534(nobody) gid=65534(nobody) groups=65534(nobody)
```

**Before tightening a namespace, ask the server what would break.** A
server-side dry run of the label change lists existing violators without
changing anything:

```bash
kubectl label --dry-run=server --overwrite ns lab-security pod-security.kubernetes.io/enforce=restricted
```

```
Warning: existing pods in namespace "lab-security" violate the new PodSecurity enforce level "restricted:v1.33"
Warning: as-root (and 1 other pod): allowPrivilegeEscalation != false, unrestricted capabilities, runAsNonRoot != true, seccompProfile
Warning: caps-dropped: allowPrivilegeEscalation != false, runAsNonRoot != true, seccompProfile
namespace/lab-security labeled (server dry run)
```

(Existing pods are never evicted by a label change; the level only applies
to new pods.)

### 6. nginx as non-root, read-only, `restricted`

```bash
kubectl apply -f modules/15-security/04-nginx-nonroot-config.yaml -f modules/15-security/05-nginx-nonroot.yaml
kubectl -n lab-security-restricted rollout status deploy/nginx-nonroot
kubectl -n lab-security-restricted exec deploy/nginx-nonroot -- ps -o user,pid,comm
```

```
deployment "nginx-nonroot" successfully rolled out
USER     PID   COMMAND
nginx        1 nginx
nginx       24 nginx
nginx       25 nginx
...
```

Even the master process (PID 1) is `nginx` (uid 101). Test it:

```bash
kubectl -n lab-security-restricted port-forward svc/nginx-nonroot 8080:80
# in a second terminal:
curl -s localhost:8080 | head -4
curl -s localhost:8080/healthz
```

```
<!DOCTYPE html>
<html>
<head>
<title>Welcome to nginx!</title>
ok
```

Where the writable bits ended up:

```bash
kubectl -n lab-security-restricted exec deploy/nginx-nonroot -- ls -la /run /var/cache/nginx
```

```
/run:
drwxrwsrwt    2 root     nginx           60 Oct  8 10:15 .
-rw-r--r--    1 nginx    nginx            2 Oct  8 10:15 nginx.pid

/var/cache/nginx:
drwxrwsrwx    7 root     nginx         4096 Oct  8 10:15 .
drwx--S---    2 nginx    nginx         4096 Oct  8 10:15 client_temp
drwx--S---    2 nginx    nginx         4096 Oct  8 10:15 proxy_temp
...
```

**What goes wrong if you skip a tweak** (all observed on this cluster - try them):

| Missing piece | Symptom |
|---|---|
| `runAsUser: 101` (only `runAsNonRoot: true`) | `CreateContainerConfigError`: `container has runAsNonRoot and image will run as root` |
| emptyDir on `/var/cache/nginx` | `CrashLoopBackOff`; logs: `[emerg] mkdir() "/var/cache/nginx/client_temp" failed (30: Read-only file system)` |
| emptyDir on `/var/run` | `CrashLoopBackOff`; `open() "/run/nginx.pid" failed (30: Read-only file system)` |
| `listen 8080` (keep port 80) | works on kind/containerd 2.x (unprivileged port sysctl), but `bind() to 0.0.0.0:80 failed (13: Permission denied)` on runtimes without it |
| no `listen [::]:8080` removal | on an IPv4-only cluster: `socket() [::]:8080 failed (97: Address family not supported by protocol)` |

The log line `the "user" directive makes sense only if the master process
runs with super-user privileges, ignored` is expected: the stock
`nginx.conf` says `user nginx;`, and we already are.

### 7. No ServiceAccount token unless needed

```bash
kubectl apply -f modules/15-security/06-serviceaccount-no-automount.yaml
kubectl -n lab-security exec as-root  -- ls /var/run/secrets/kubernetes.io/serviceaccount
kubectl -n lab-security exec no-token -- ls /var/run/secrets/kubernetes.io/serviceaccount
```

```
ca.crt
namespace
token
ls: /var/run/secrets/kubernetes.io/serviceaccount: No such file or directory
command terminated with exit code 1
```

### 8. Pin images by digest

```bash
kubectl apply -f modules/15-security/07-image-digest.yaml
kubectl -n lab-security logs pinned
kubectl -n lab-security get pod pinned -o jsonpath='{.spec.containers[0].image}{"\n"}{.status.containerStatuses[0].imageID}{"\n"}'
```

```
nginx version: nginx/1.27.5
nginx:1.27-alpine@sha256:65645c7bb6a0661892a8b03b89d0743208a18dd2f3f17a54ef4b76fb8e2f2a10
docker.io/library/nginx@sha256:65645c7bb6a0661892a8b03b89d0743208a18dd2f3f17a54ef4b76fb8e2f2a10
```

`imageID` is what actually ran. For *any* pod, that field tells you the
digest to pin - a handy way to "freeze" what you have today.

### 9. Secrets hygiene

```bash
kubectl apply -f modules/15-security/08-secret-hygiene.yaml
kubectl -n lab-security exec secret-reader -- ls -ln /etc/creds/..data/
kubectl -n lab-security exec secret-reader -- mount | grep creds
kubectl -n lab-security get secret db-creds -o jsonpath='{.data.password}' | base64 -d; echo
```

```
-r--r-----    1 0        1000            19 Oct  8 10:16 password
-r--r-----    1 0        1000             3 Oct  8 10:16 username
tmpfs on /etc/creds type tmpfs (ro,relatime,size=32768k,noswap)
not-a-real-password
```

* Files are mode `0440`, group `1000` (the pod's `fsGroup`) - readable by the
  app, nobody else; mounted read-only on a **tmpfs** (never written to the
  node's disk).
* The last line is the uncomfortable truth: `base64` is an *encoding*.
  Anyone with `get secret` can read it. See the comments in the file and the
  checklist for what to do about it.
* The Secret is `immutable: true`. Try to change a value:
  `kubectl -n lab-security patch secret db-creds -p '{"stringData":{"password":"x"}}'`
  gives `The Secret "db-creds" is invalid: data: Forbidden: field is immutable when 'immutable' is set`.
  To change it you must delete and recreate it (and restart the pods) - a
  deliberate, controlled rollout, which is what you want for credentials.
  (A common pattern: put a version in the name, `db-creds-v2`, and update the
  Deployment to point at it - see Kustomize's `secretGenerator` in module 17.)

### 10. Your own rules: ValidatingAdmissionPolicy

```bash
kubectl apply -f modules/15-security/09-vap-deny-latest.yaml -f modules/15-security/10-vap-require-resources.yaml
kubectl get validatingadmissionpolicies,validatingadmissionpolicybindings
```

```
NAME                                                                                    VALIDATIONS   PARAMKIND   AGE
validatingadmissionpolicy.admissionregistration.k8s.io/lab-security-deny-latest-tag     1             <unset>     5s
validatingadmissionpolicy.admissionregistration.k8s.io/lab-security-require-resources   1             <unset>     5s

NAME                                                                                           POLICYNAME                       PARAMREF   AGE
validatingadmissionpolicybinding.admissionregistration.k8s.io/lab-security-deny-latest-tag     lab-security-deny-latest-tag     <unset>    5s
validatingadmissionpolicybinding.admissionregistration.k8s.io/lab-security-require-resources   lab-security-require-resources   <unset>    5s
```

Give the API server a second or two to load new policies, then try the three
offenders (the PSA warnings are also printed - two independent admission
layers - trimmed here):

```bash
kubectl apply -f modules/15-security/vap/01-latest-tag-pod.yaml
kubectl apply -f modules/15-security/vap/02-untagged-deployment.yaml
kubectl apply -f modules/15-security/vap/03-no-limits-pod.yaml
```

```
The pods "latest-tag" is invalid: : ValidatingAdmissionPolicy 'lab-security-deny-latest-tag' with binding 'lab-security-deny-latest-tag' denied request: images must be pinned to a version tag (not :latest) or a digest; offending containers: app=busybox:latest
The deployments "untagged" is invalid: : ValidatingAdmissionPolicy 'lab-security-deny-latest-tag' with binding 'lab-security-deny-latest-tag' denied request: images must be pinned to a version tag (not :latest) or a digest; offending containers: init=busybox
The pods "no-limits" is invalid: : ValidatingAdmissionPolicy 'lab-security-require-resources' with binding 'lab-security-require-resources' denied request: every container needs resources.requests.cpu, resources.requests.memory and resources.limits.memory; missing in: sidecar
```

Things to notice:

* Unlike PSA, policy 09 also matches **Deployments**, so the bad Deployment is
  rejected at `apply` time instead of failing quietly later.
* The `messageExpression` names the offending container - good policies tell
  people how to fix the problem.
* The policy treats `localhost:5000/app` (registry port, no tag) as untagged
  and `localhost:5000/app:1.0` as fine, because it only looks for `:` after
  the last `/`. Check with a server-side dry run:
  `kubectl -n lab-security run t --image=localhost:5000/app --dry-run=server`.
* The bindings only select `lab-security`; the same pods in any other
  namespace are not affected.

### 11. Debugging a locked-down pod

`kubectl debug` (module 16) adds an *ephemeral container* to a running pod,
and PSA checks it like any other container:

```bash
POD=$(kubectl -n lab-security-restricted get pod -l app=nginx-nonroot -o name | head -1)
kubectl -n lab-security-restricted debug $POD -it --image=busybox:1.37 --target=nginx
```

```
Error from server (Forbidden): pods "nginx-nonroot-6dbf7b7cbd-dncc9" is forbidden: violates PodSecurity "restricted:v1.33": allowPrivilegeEscalation != false (container "debugger-gh8ht" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "debugger-gh8ht" must set securityContext.capabilities.drop=["ALL"])
```

Use the `restricted` debugging profile, which sets a compliant
securityContext on the debug container:

```bash
kubectl -n lab-security-restricted debug $POD -it --image=busybox:1.37 --target=nginx --profile=restricted
# inside:  id; ps        (you see nginx's processes, as uid 101)
```

```
uid=101 gid=101 groups=101
PID   USER     TIME  COMMAND
    1 101       0:00 nginx: master process nginx -g daemon off;
   24 101       0:00 nginx: worker process
```

## Exercises

1. **What would break?** Without changing anything, find out which pods in
   `lab-security` would violate the `baseline` level, and which would violate
   `restricted`.
   *Hint:* step 5's `kubectl label --dry-run=server`. (Answer: none for
   baseline - that's why they were admitted.)

2. **Harden the root pod.** Copy `01-pod-root.yaml`, change it so it is admitted
   into `lab-security-restricted`, apply it and confirm `id` no longer says root.
   *Hint:* busybox's image user is root, so `runAsNonRoot: true` alone gives
   `CreateContainerConfigError`. Solution:
   [`solutions/ex2-as-root-restricted.yaml`](solutions/ex2-as-root-restricted.yaml).

3. **Roll out a policy safely.** Change the binding of policy 09 to
   `validationActions: ["Warn", "Audit"]`, apply `vap/01-latest-tag-pod.yaml`
   again and compare. Then delete the pod and restore `Deny`.
   Solution: [`solutions/ex3-binding-warn.yaml`](solutions/ex3-binding-warn.yaml)
   (you should see `Warning: Validation failed for ValidatingAdmissionPolicy ...`
   followed by `pod/latest-tag created`).

4. **Redis under `restricted`.** Run `redis:7.4-alpine` as a Deployment in
   `lab-security-restricted` with a read-only root filesystem, and prove it
   works with `redis-cli SET`/`GET`.
   *Hints:* `docker run --rm --entrypoint id redis:7.4-alpine redis` shows the
   uid/gid to use; redis writes to `/data`.
   Solution: [`solutions/ex4-redis-restricted.yaml`](solutions/ex4-redis-restricted.yaml).

5. **Policy for workloads.** Policy 10 only checks Pods, so a Deployment
   without resources is accepted and then its pods fail. Extend it to
   Deployments, StatefulSets, DaemonSets and Jobs, include init containers,
   and make the message say which object and which containers are at fault.
   Test with `kubectl -n lab-security create deployment nolimits --image=busybox:1.37 -- sleep 3600`.
   *Hint:* reuse the `podSpec` variable trick from policy 09.
   Solution: [`solutions/ex5-vap-require-resources-workloads.yaml`](solutions/ex5-vap-require-resources-workloads.yaml)
   (it replaces policy 10 - re-apply `10-vap-require-resources.yaml` to go back).

6. **Stretch: allowed registries.** Write a VAP that only allows images from
   `docker.io` (written either as `docker.io/...` or with no registry at all)
   in `lab-security`. What about `ghcr.io/...`? How would you make the list of
   registries configurable per namespace without editing the policy?
   *Hint:* look up `paramKind` / `paramRef` in the VAP docs - a ConfigMap can
   hold the parameters.

## Cleanup

```bash
kubectl delete namespace lab-security lab-security-restricted
kubectl delete validatingadmissionpolicybinding lab-security-deny-latest-tag lab-security-require-resources
kubectl delete validatingadmissionpolicy lab-security-deny-latest-tag lab-security-require-resources
```

The policies are cluster-scoped, so deleting the namespaces does **not**
remove them.

## Further reading

* [Configure a Security Context for a Pod or Container](https://kubernetes.io/docs/tasks/configure-pod-container/security-context/)
* [Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
* [Pod Security Admission](https://kubernetes.io/docs/concepts/security/pod-security-admission/) and
  [Enforce Pod Security Standards with namespace labels](https://kubernetes.io/docs/tasks/configure-pod-container/enforce-standards-namespace-labels/)
* [Validating Admission Policy](https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/) and
  [CEL in Kubernetes](https://kubernetes.io/docs/reference/using-api/cel/)
* [Images: pull policy and digests](https://kubernetes.io/docs/concepts/containers/images/)
* [Service Accounts](https://kubernetes.io/docs/concepts/security/service-accounts/)
* [Good practices for Kubernetes Secrets](https://kubernetes.io/docs/concepts/security/secrets-good-practices/) and
  [Encrypting Secret Data at Rest](https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/)
* [Restrict a Container's Syscalls with seccomp](https://kubernetes.io/docs/tutorials/security/seccomp/)
* [User Namespaces](https://kubernetes.io/docs/concepts/workloads/pods/user-namespaces/)
* [Security checklist](https://kubernetes.io/docs/concepts/security/security-checklist/)
* Related modules: [11 - RBAC](../11-rbac/README.md), [13 - NetworkPolicies](../13-network-policies/README.md),
  [16 - Debugging](../16-debugging/README.md)
