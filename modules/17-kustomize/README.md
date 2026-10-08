# Module 17 - Kustomize

## Goal

Keep one set of plain Kubernetes YAML and produce a correct variant per
environment (dev, prod, ...) without copy-paste and without templates.

## What you'll learn

* How Kustomize works: a **base**, **overlays** on top, and transformers - no templating
* `namespace`, `namePrefix` / `nameSuffix`, `labels` (and why `commonLabels` is deprecated), `replicas`, `images`
* `configMapGenerator` / `secretGenerator`, the **hash suffix**, and why it makes config changes roll out
* Patches: strategic merge vs JSON 6902, inline vs file, `target` selectors
* **Components** for optional, reusable features
* `kubectl kustomize` vs `kubectl apply -k`, and previewing changes with `kubectl diff -k`

## Concepts

### Base + overlays

```
base/                          overlays/dev/                    overlays/prod/
  deployment.yaml   <------      resources: [../../base]          resources: [../../base]
  service.yaml                   namespace: lab-kustomize-dev     namespace: lab-kustomize-prod
  kustomization.yaml             namePrefix: dev-                 nameSuffix: -prod
    (configMapGenerator,         replicas: 1                      replicas: 3
     secretGenerator,            config: merge WHOAMI_NAME        images: pin digest
     labels)                                                      patches: resources, rollout
                                                                  components: [pdb]
```

A **kustomization** (`kustomization.yaml`) lists resources and the
transformations to apply to them. Kustomize loads the resources, runs
generators (ConfigMaps/Secrets), applies transformers (namespace, names,
labels, images, replicas, patches) and prints the result. The output is
plain YAML - nothing is stored in the cluster except the objects
themselves. There is no templating language: every input file is valid
Kubernetes YAML you can read and lint.

Kustomize is built into kubectl (`kubectl version` shows which version;
kubectl 1.37 ships Kustomize v5.8). The standalone `kustomize` binary adds
editing commands such as `kustomize edit set image`, used by CI pipelines.

| Command | What it does |
|---|---|
| `kubectl kustomize <dir>` | render to stdout, touch nothing (same as `kustomize build <dir>`) |
| `kubectl apply -k <dir>` | render + apply (same as `kubectl kustomize <dir> \| kubectl apply -f -`) |
| `kubectl diff -k <dir>` | render + server-side diff against the live objects (exit code 0 = no changes, 1 = changes, >1 = error) |
| `kubectl delete -k <dir>` | render + delete exactly those objects |

### Name references

When Kustomize renames something (prefix/suffix, generator hash), it also
updates every **reference** to it it knows about: `envFrom.configMapRef`,
`secretKeyRef`, volumes, a Service's name in an Ingress backend, a
ServiceAccount in a pod spec, etc. That's why `name: app-config` in the
base Deployment becomes `dev-app-config-f7m97f86ht` in dev.

### Generators and the hash suffix

```
configMapGenerator: app-config  --->  ConfigMap app-config-<hash of content>
                                          ^
Deployment envFrom: app-config  ------->  rewritten to the same hashed name
```

Change one value and the hash, therefore the name, changes. The pod
template now references a different ConfigMap, so the Deployment sees a
template change and **rolls out new pods** with the new config. Without the
hash, updating a ConfigMap in place does *not* restart pods, and env vars
are only read at container start - the classic "I changed the ConfigMap and
nothing happened". Bonus: the old ConfigMap still exists, so
`kubectl rollout undo` restores the old config too.

The downside: old ConfigMaps/Secrets pile up. `kubectl apply -k` doesn't
delete them; GitOps tools (Argo CD, Flux) prune them, or you clean up by label.

`behavior` in an overlay's generator: `create` (default, new object),
`merge` (add/override keys of the base's generator), `replace` (throw the
base's content away). `generatorOptions.disableNameSuffixHash: true` turns
the hash off (exercise 5 shows what you lose).

### Labels: `labels` instead of `commonLabels`

`commonLabels` adds labels everywhere *including selectors*. A Deployment's
`spec.selector` is immutable, so changing a common label later makes
`kubectl apply` fail; adding one to a running app orphans the old
ReplicaSet's pods. Use `labels` with `includeSelectors: false` (and
`includeTemplates: true` to label pods too). Other deprecated fields you'll
see in older repos: `patchesStrategicMerge` / `patchesJson6902` (use
`patches`), `bases` (use `resources`), `vars` (use `replacements`).
`kustomize edit fix` migrates them.

### Two kinds of patch

| | Strategic merge patch | JSON 6902 patch |
|---|---|---|
| Looks like | a partial Kubernetes object | a list of `op` / `path` / `value` operations |
| Finds its target by | its own `kind` + `metadata.name` (or `target:`) | `target:` (required) |
| Lists | merged by key (containers by `name`, ports by `containerPort`, ...) | addressed by index: `/containers/0/...` |
| Good at | adding/overriding fields, readable | removing fields, replacing whole lists, precise edits, `test` guards |

Both go under `patches:` either as `path:` (a file) or inline `patch: |-`.
A `target` can select by `group`/`version`/`kind`/`name`/`namespace` and
`labelSelector`/`annotationSelector`, so one patch can hit many objects.

### Components

A `kind: Component` kustomization is a reusable bundle of resources and
patches that an overlay opts into with `components:`. Unlike a base, it is
applied *into* the including kustomization, so it can patch the overlay's
resources. Use it for optional features: a PodDisruptionBudget only in prod
and staging, an Ingress, a monitoring sidecar, debug settings.

### Kustomize or Helm?

Kustomize: patch plain YAML you own, no templating, built into kubectl.
Helm ([module 18](../18-helm/README.md)): packages with parameters
(`values.yaml`), releases with history and rollback, a large ecosystem of
third-party charts. Many teams use both - e.g. render a third-party Helm
chart and patch the result with Kustomize, or let Argo CD/Flux do either.

## Files

| File | What it demonstrates |
|---|---|
| [`base/kustomization.yaml`](base/kustomization.yaml) | `resources`, `labels`, `configMapGenerator`, `secretGenerator` |
| [`base/deployment.yaml`](base/deployment.yaml) | traefik/whoami reading `app-config` (envFrom) and `app-secret` (secretKeyRef) |
| [`base/service.yaml`](base/service.yaml) | ClusterIP Service |
| [`overlays/dev/kustomization.yaml`](overlays/dev/kustomization.yaml) | `namespace`, `namePrefix`, `labels`, `replicas`, generator `merge`/`replace` with literals |
| [`overlays/dev/namespace.yaml`](overlays/dev/namespace.yaml) | the `lab-kustomize-dev` Namespace |
| [`overlays/prod/kustomization.yaml`](overlays/prod/kustomization.yaml) | `nameSuffix`, `replicas`, `images` (digest pin), `secretGenerator` from an env file, three kinds of patches, `components` |
| [`overlays/prod/patches/resources.yaml`](overlays/prod/patches/resources.yaml) | strategic-merge patch: resources + topology spread |
| [`overlays/prod/patches/rollout.yaml`](overlays/prod/patches/rollout.yaml) | JSON 6902 patch: rollout strategy, minReadySeconds, probe period |
| [`overlays/prod/secrets.env`](overlays/prod/secrets.env) | input for `secretGenerator` (demo value - see the warning in it) |
| [`components/pdb/`](components/pdb/) | a Component adding a PodDisruptionBudget |
| [`solutions/staging/`](solutions/staging/) | exercise 1: a third overlay |
| [`solutions/dev-no-probe/`](solutions/dev-no-probe/) | exercise 4: an overlay on an overlay, JSON patch `remove` + `test` |

Unlike other modules there are no numbered top-level manifests: everything
is applied with `-k <directory>`. The overlays create their namespaces
(`lab-kustomize-dev`, `lab-kustomize-prod`) themselves.

## Lab

All commands are run from the repo root.

### 1. Render the base

```bash
kubectl kustomize modules/17-kustomize/base
```

Look for three things in the output (trimmed):

```yaml
kind: ConfigMap
metadata:
  labels:
    app.kubernetes.io/name: web
    app.kubernetes.io/part-of: kustomize-lab
  name: app-config-4c8c79gkfm          # <- generated name with content hash
...
kind: Deployment
spec:
  selector:
    matchLabels:
      app: web                         # <- selector untouched (includeSelectors: false)
  template:
    metadata:
      labels:
        app: web
        app.kubernetes.io/name: web    # <- but pods do get the labels (includeTemplates: true)
...
        envFrom:
        - configMapRef:
            name: app-config-4c8c79gkfm  # <- reference rewritten to match
```

(Your hashes may differ from the ones shown here if you change any value.)

### 2. Render dev and prod side by side

```bash
kubectl kustomize modules/17-kustomize/overlays/dev  > /tmp/dev.yaml
kubectl kustomize modules/17-kustomize/overlays/prod > /tmp/prod.yaml
diff /tmp/dev.yaml /tmp/prod.yaml | less     # or: code --diff /tmp/dev.yaml /tmp/prod.yaml
grep -E '^  name:|namespace:|replicas:|image:' /tmp/prod.yaml
```

What the prod overlay changed, and which feature did it:

| In the output | Comes from |
|---|---|
| `namespace: lab-kustomize-prod` on every namespaced object | `namespace:` |
| `web-prod`, `app-config-prod-g959m486cf`, `app-secret-prod-bk8ft7kk2b` | `nameSuffix: -prod` + generator hash |
| `replicas: 3` | `replicas:` |
| `image: traefik/whoami@sha256:1699d99c...` | `images:` with `digest:` |
| `WHOAMI_NAME: kustomize-prod`, `FEATURE_SEARCH: "off"` kept from base | `configMapGenerator` `behavior: merge` |
| `API_TOKEN: cHJvZC10b2tlbi1kZW1vLW9ubHk=` (base64 of the env file value) | `secretGenerator` `behavior: replace` + `envs:` |
| bigger `resources`, `topologySpreadConstraints` | strategic-merge patch `patches/resources.yaml` |
| `strategy.rollingUpdate.maxUnavailable: 0`, `minReadySeconds: 5`, `periodSeconds: 3` | JSON 6902 patch `patches/rollout.yaml` |
| `annotations: lab.example.com/owner: team-web` on the Service | inline JSON 6902 patch with a `target` |
| a `PodDisruptionBudget` named `web-prod` | the `pdb` component |

### 3. Preview, then apply

```bash
kubectl diff -k modules/17-kustomize/overlays/dev
```

```
Error from server (NotFound): namespaces "lab-kustomize-dev" not found
```

`diff` does a server-side dry run of every object, and namespaced objects
can't be dry-run into a namespace that doesn't exist yet. On a first
deployment just apply (or create the namespace first):

```bash
kubectl apply -k modules/17-kustomize/overlays/dev
kubectl apply -k modules/17-kustomize/overlays/prod
kubectl -n lab-kustomize-prod rollout status deploy/web-prod
```

```
namespace/lab-kustomize-dev created
configmap/dev-app-config-f7m97f86ht created
secret/dev-app-secret-t9t8f6cgm5 created
service/dev-web created
deployment.apps/dev-web created
namespace/lab-kustomize-prod created
configmap/app-config-prod-g959m486cf created
secret/app-secret-prod-bk8ft7kk2b created
service/web-prod created
deployment.apps/web-prod created
poddisruptionbudget.policy/web-prod created
deployment "web-prod" successfully rolled out
```

```bash
kubectl get deploy,pods,pdb -n lab-kustomize-prod -o wide
```

```
NAME                       READY   UP-TO-DATE   AVAILABLE   AGE   CONTAINERS   IMAGES                                                                                   SELECTOR
deployment.apps/web-prod   3/3     3            3           7s    whoami       traefik/whoami@sha256:1699d99cb4b9acc17f74ca670b3d8d0b7ba27c948b3445f0593b58ebece92f04   app=web

NAME                           READY   STATUS    RESTARTS   AGE   IP            NODE                    ...
pod/web-prod-bb7bb6b89-4jhq8   1/1     Running   0          7s    10.244.3.38   kube-training-worker    ...
pod/web-prod-bb7bb6b89-pk7kr   1/1     Running   0          7s    10.244.1.25   kube-training-worker2   ...
pod/web-prod-bb7bb6b89-sn7d9   1/1     Running   0          7s    10.244.3.39   kube-training-worker    ...

NAME                                  MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS   AGE
poddisruptionbudget.policy/web-prod   N/A             1                 1                     7s
```

The topology spread patch put the three pods across both zones (2 + 1).

Ask the dev app who it is:

```bash
kubectl -n lab-kustomize-dev port-forward svc/dev-web 8080:80
# second terminal:
curl -s localhost:8080 | head -2
```

```
Name: kustomize-dev
Hostname: dev-web-5b47df8b85-9ngm9
```

### 4. Change config -> new hash -> rollout

Edit `modules/17-kustomize/overlays/dev/kustomization.yaml` and change
`WHOAMI_NAME=kustomize-dev` to `WHOAMI_NAME=kustomize-dev-v2`. Then preview:

```bash
kubectl diff -k modules/17-kustomize/overlays/dev
```

```diff
@@ -45,7 +45,7 @@
         envFrom:
         - configMapRef:
-            name: dev-app-config-f7m97f86ht
+            name: dev-app-config-9b7h84g26f
         image: traefik/whoami:v1.10
...
+++ /tmp/MERGED-.../v1.ConfigMap.lab-kustomize-dev.dev-app-config-9b7h84g26f
@@ -0,0 +1,15 @@
+apiVersion: v1
+data:
+  DEBUG: "true"
+  FEATURE_SEARCH: "on"
+  WHOAMI_NAME: kustomize-dev-v2
+kind: ConfigMap
```

A **new** ConfigMap, and the Deployment's pod template points at it.
Apply and watch:

```bash
kubectl apply -k modules/17-kustomize/overlays/dev
kubectl -n lab-kustomize-dev rollout status deploy/dev-web
kubectl -n lab-kustomize-dev rollout history deploy/dev-web
kubectl -n lab-kustomize-dev get configmaps
```

```
configmap/dev-app-config-9b7h84g26f created
secret/dev-app-secret-t9t8f6cgm5 unchanged
service/dev-web unchanged
deployment.apps/dev-web configured
deployment "dev-web" successfully rolled out
REVISION  CHANGE-CAUSE
1         <none>
2         <none>

NAME                        DATA   AGE
dev-app-config-9b7h84g26f   3      3s
dev-app-config-f7m97f86ht   3      45s
kube-root-ca.crt            1      45s
```

The old ConfigMap is still there - which is exactly what makes
`kubectl -n lab-kustomize-dev rollout undo deploy/dev-web` restore the old
config as well. Port-forward again and `curl` shows `Name: kustomize-dev-v2`.
Change the value back when you're done (`git checkout modules/17-kustomize/overlays/dev/kustomization.yaml`).

### 5. Where kustomize stops

Things worth knowing before you rely on it:

* `kubectl apply -k` never deletes objects you removed from the
  kustomization. Remove them with `kubectl delete`, or use a GitOps tool that prunes.
* A base can be a remote git URL (`resources: [https://github.com/org/repo//path?ref=v1.2.0]`).
  Always pin `ref` to a tag or commit.
* The JSON patch path `/spec/template/spec/containers/0/...` silently means
  "the first container". If someone reorders containers, the patch edits the
  wrong one - add an `op: test` guard (see [`solutions/dev-no-probe/`](solutions/dev-no-probe/kustomization.yaml)).

## Exercises

1. **A staging environment.** Create a third overlay that deploys to
   `lab-kustomize-staging` with 2 replicas, prefix `staging-`, its own
   `WHOAMI_NAME`, and the PDB component. Apply it and check `kubectl get deploy,pdb`.
   Solution: [`solutions/staging/`](solutions/staging/kustomization.yaml).

2. **PDB in dev?** Add the `pdb` component to the dev overlay and look at
   `ALLOWED DISRUPTIONS` in `kubectl get pdb`. Now imagine the PDB said
   `minAvailable: 1` instead of `maxUnavailable: 1`. What would happen to
   `kubectl drain` on the node running dev's single replica?
   *Hint:* with one replica, `minAvailable: 1` allows 0 disruptions - drains
   block forever. That's why the component uses `maxUnavailable`.

3. **Promote an image.** In the dev overlay, add an `images:` entry that
   changes the tag to `v1.11` and run `kubectl diff -k` (no need to apply).
   Which objects change? Then try the CI way with the standalone binary:
   `cd modules/17-kustomize/overlays/dev && kustomize edit set image traefik/whoami=traefik/whoami:v1.11`
   and look at what it wrote into `kustomization.yaml`.

4. **Remove, don't merge.** Build an overlay *on top of* `overlays/dev` that
   removes the readiness probe with a JSON 6902 patch, guarded by an `op:
   test` that checks the first container is `whoami`. What name must the
   patch target use - `web` or `dev-web` - and why?
   Solution: [`solutions/dev-no-probe/`](solutions/dev-no-probe/kustomization.yaml).

5. **Life without the hash.** Add
   ```yaml
   generatorOptions:
     disableNameSuffixHash: true
   ```
   to the dev overlay, apply, then change `WHOAMI_NAME` again and apply.
   Is there a rollout? What does `curl` return, and what does
   `kubectl get cm dev-app-config -o yaml` say?
   *Answer:* the ConfigMap is updated in place (`configmap/dev-app-config
   configured`), the Deployment is `unchanged`, no new pods - the app keeps
   serving the old name until something restarts it. Clean up the extra
   un-hashed objects afterwards (`kubectl delete -k` then re-apply the original).

## Cleanup

```bash
kubectl delete -k modules/17-kustomize/overlays/dev
kubectl delete -k modules/17-kustomize/overlays/prod
kubectl delete namespace lab-kustomize-staging --ignore-not-found   # exercise 1
```

`delete -k` deletes the Namespace objects too, which removes anything left in
them (old hashed ConfigMaps included).

## Further reading

* [Declarative Management of Kubernetes Objects Using Kustomize](https://kubernetes.io/docs/tasks/manage-kubernetes-objects/kustomization/)
* [Kustomize reference (kubectl.docs.kubernetes.io)](https://kubectl.docs.kubernetes.io/references/kustomize/)
* [Kustomize components](https://kubectl.docs.kubernetes.io/guides/config_management/components/)
* [Strategic merge patch](https://kubernetes.io/docs/tasks/manage-kubernetes-objects/update-api-object-kubectl-patch/) and [RFC 6902 JSON Patch](https://datatracker.ietf.org/doc/html/rfc6902)
* [ConfigMaps](https://kubernetes.io/docs/concepts/configuration/configmap/) - why updates don't restart pods
* Related: [module 05 - ConfigMaps & Secrets](../05-config-secrets/README.md), [module 18 - Helm](../18-helm/README.md)
