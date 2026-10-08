# Module 18 - Helm

## Goal

Package an application as a Helm chart, install and upgrade it with
different values, roll it back, test it - and know how to use other
people's charts safely.

## What you'll learn

* Installing a pinned Helm (v4) and what changed from Helm 3
* Chart anatomy: `Chart.yaml`, `values.yaml`, `templates/`, `_helpers.tpl`, `NOTES.txt`, tests, `values.schema.json`
* Go templates in practice: `include`, `nindent`, `toYaml`, `with`, `if`, `default`, `quote`, `sha256sum`
* The release lifecycle: `lint` -> `template` -> `install --dry-run` -> `install` -> `upgrade` (`--set`, `-f`) -> `history` -> `rollback` -> `uninstall`
* How values are merged, and the `--reuse-values` trap
* Hooks (a pre-install/pre-upgrade Job) and `helm test`
* Finding, inspecting and installing public charts (`helm repo add`, `helm search`, `helm show values`, OCI charts)

## Concepts

### Chart, values, release

```
chart (a directory or .tgz)        values (defaults + your overrides)
  Chart.yaml                          chart/values.yaml
  values.yaml          ----+          -f values-prod.yaml
  values.schema.json       |          --set replicaCount=3
  templates/*.yaml         |              |
                           v              v
                    helm renders templates with the merged values
                                   |
                                   v
                 Kubernetes objects + a RELEASE record (revision N)
                 stored as a Secret sh.helm.release.v1.<release>.v<N>
```

* A **chart** is a package of templates. `version` in `Chart.yaml` versions
  the chart; `appVersion` is the version of the app inside it.
* A **release** is one installation of a chart in a namespace, under a name
  (`hello`). You can install the same chart many times with different names.
* Every install/upgrade/rollback creates a new **revision**. Helm keeps the
  rendered manifests and values of each one (as Secrets in the release
  namespace), which is what makes `helm history` and `helm rollback` work.

### How values are merged

Lowest to highest priority:

1. `values.yaml` in the chart
2. `-f file1.yaml -f file2.yaml` (left to right)
3. `--set` / `--set-string` / `--set-json` / `--set-file` (left to right)

Maps are merged key by key; **lists are replaced** as a whole. On
`helm upgrade`, Helm starts again from the chart defaults: values you passed
to a *previous* revision are **dropped** unless you pass them again (or use
`--reuse-values`, which has its own surprises when the chart's defaults
change - `--reset-then-reuse-values` is usually what you want). The lab
shows this happening. (One exception: an upgrade with no `-f`/`--set` at
all quietly reuses the previous revision's values.)

`values.schema.json` (JSON Schema) validates the merged values on
`lint`, `template`, `install` and `upgrade`. Typos in `--set` keys and wrong
types fail fast instead of rendering something silently wrong.

### Template building blocks used in this chart

| Construct | Example | What it does |
|---|---|---|
| value lookup | `{{ .Values.replicaCount }}` | insert a value |
| built-in objects | `.Release.Name`, `.Release.Namespace`, `.Chart.AppVersion`, `.Template.BasePath` | release / chart metadata |
| named template | `{{ include "webapp.labels" . \| nindent 4 }}` | reuse a block from `_helpers.tpl`, indented 4 spaces on a new line |
| subtree | `{{- toYaml .Values.resources \| nindent 12 }}` | copy a whole map from values |
| default | `.Values.image.tag \| default .Chart.AppVersion` | fallback when empty |
| condition | `{{- if .Values.ingress.enabled }}` | optional objects |
| scope | `{{- with .Values.nodeSelector }} ... {{ toYaml . }}` | render only if non-empty, `.` becomes the value |
| checksum | `{{ include (print $.Template.BasePath "/configmap.yaml") . \| sha256sum }}` | pod annotation that changes when the ConfigMap changes -> rollout |
| whitespace | `{{-` / `-}}` | trim whitespace/newlines left/right of the tag |

### Hooks

Annotating a template with `helm.sh/hook` takes it out of the normal object
set and runs it at a lifecycle point: `pre-install`, `post-install`,
`pre-upgrade`, `post-upgrade`, `pre-rollback`, `post-rollback`,
`pre-delete`, `post-delete`, `test`. Helm waits for hook Jobs/Pods to finish
(and fails the operation if they fail) before continuing. Typical uses:
database migrations, backups before upgrade, smoke tests.

`helm.sh/hook-weight` orders hooks of the same kind;
`helm.sh/hook-delete-policy` (`before-hook-creation`, `hook-succeeded`,
`hook-failed`) controls cleanup. Hook objects are **not** part of the
release, so `helm uninstall` doesn't remove them unless a delete policy does.

Hooks give you ordering *between Helm phases*. They are not the only
ordering tool: init containers, readiness gates, StatefulSet ordinal
ordering and Job dependencies order things *inside* the cluster. The
[RWO PVC scenario](../../scenarios/rwo-pvc-ordered-pods/README.md) compares
those patterns for a volume that must be used by one pod after another.

### Helm 4 vs Helm 3

Helm 4 (current major version; this module pins **v4.3.0**) keeps the chart
format (`apiVersion: v2` charts work unchanged) and the everyday commands.
Changes you will notice when reading older docs or scripts:

| Helm 3 | Helm 4 |
|---|---|
| client-side 3-way merge apply | **server-side apply** by default for new releases (`--server-side`; upgrades follow the release's previous method) |
| `--atomic` | `--rollback-on-failure` |
| `--force` | `--force-replace` (and `--force-conflicts` for server-side apply conflicts) |
| `--wait` (checks a fixed list of kinds) | `--wait` = `--wait=watcher` (kstatus-based readiness of every object); `--wait=legacy` for the old logic; default without the flag is `hookOnly` |
| `--dry-run` | `--dry-run=client` or `--dry-run=server` (bare `--dry-run` prints a deprecation warning) |
| post-renderer = any executable | post-renderer must be a Helm plugin |
| `--debug` plain text | structured log lines (`level=DEBUG msg=...`) |

### Public charts

* **Classic repositories** are an HTTP server with an `index.yaml`:
  `helm repo add <name> <url>` + `helm repo update`, then refer to
  `<name>/<chart>`. `helm search repo <word>` searches the repos you added;
  `helm search hub <word>` searches [Artifact Hub](https://artifacthub.io).
* **OCI registries** store charts like container images. No `repo add`:
  use the full reference, e.g. `oci://ghcr.io/stefanprodan/charts/podinfo`.
  Most projects now publish this way.
* Before installing anything: pin `--version`, read `helm show values` (and
  `helm show readme`), render it with `helm template` and read what it creates
  - especially RBAC and anything cluster-scoped. Prefer charts published by
  the project itself, with signed releases.
* Note on **Bitnami**: for years `bitnami/*` was the default answer for
  "a chart for X". In 2025 Bitnami moved most of its free, versioned images to
  an unmaintained legacy repository and restricted the free catalogue, so its
  charts are no longer a good default for new work. Use the upstream
  project's own chart or operator (e.g. CloudNativePG for PostgreSQL) instead.

## Files

| File | What it is |
|---|---|
| [`00-namespace.yaml`](00-namespace.yaml) | `lab-helm`, with Pod Security labels (enforce baseline, warn restricted) |
| [`chart/Chart.yaml`](chart/Chart.yaml) | chart metadata: `apiVersion: v2`, `version`, `appVersion`, `kubeVersion` |
| [`chart/values.yaml`](chart/values.yaml) | default values, commented |
| [`chart/values.schema.json`](chart/values.schema.json) | JSON Schema for the values (types, ranges, no `:latest`, no unknown keys) |
| [`chart/templates/_helpers.tpl`](chart/templates/_helpers.tpl) | named templates: names, labels, selector labels, image, security contexts |
| [`chart/templates/configmap.yaml`](chart/templates/configmap.yaml) | nginx config + HTML page built from values |
| [`chart/templates/deployment.yaml`](chart/templates/deployment.yaml) | non-root nginx (module 15 style), checksum annotation, optional scheduling blocks |
| [`chart/templates/service.yaml`](chart/templates/service.yaml), [`serviceaccount.yaml`](chart/templates/serviceaccount.yaml) | Service and ServiceAccount (token automount off) |
| [`chart/templates/ingress.yaml`](chart/templates/ingress.yaml) | optional Ingress (`ingress.enabled`) |
| [`chart/templates/pre-install-migration-job.yaml`](chart/templates/pre-install-migration-job.yaml) | pre-install/pre-upgrade hook Job |
| [`chart/templates/tests/test-connection.yaml`](chart/templates/tests/test-connection.yaml) | `helm test` pod: curls the Service and checks the message |
| [`chart/templates/NOTES.txt`](chart/templates/NOTES.txt) | text printed after install/upgrade |
| [`values-prod.yaml`](values-prod.yaml) | production overrides: replicas, resources, anti-affinity, Ingress |
| [`solutions/pdb.yaml`](solutions/pdb.yaml) | exercise 1: optional PodDisruptionBudget template |

## Lab

All commands are run from the repo root.

### 1. Install Helm (pinned)

Pick one:

```bash
# macOS / Linux with Homebrew
brew install helm

# Linux (amd64) - pinned version, checksum verified
HELM_VERSION=v4.3.0
curl -fsSLO "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz"
curl -fsSLO "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz.sha256sum"
sha256sum -c "helm-${HELM_VERSION}-linux-amd64.tar.gz.sha256sum"
tar -xzf "helm-${HELM_VERSION}-linux-amd64.tar.gz"
sudo install linux-amd64/helm /usr/local/bin/helm
# (arm64 / macOS: replace linux-amd64 with linux-arm64, darwin-arm64, ...)

# Windows
winget install Helm.Helm
```

```bash
helm version
```

```
version.BuildInfo{Version:"v4.3.0", GitCommit:"bec5b06ed841fe5269972d864d5177944fd5970f", GitTreeState:"clean", GoVersion:"go1.27.1", KubeClientVersion:"v1.37"}
```

Helm uses your kubeconfig and current context, like kubectl. It has no
server-side component.

### 2. Read the chart, then lint it

Open the files in `modules/18-helm/chart/` in this order: `Chart.yaml`,
`values.yaml`, `templates/_helpers.tpl`, `templates/deployment.yaml`. Then:

```bash
helm lint modules/18-helm/chart
helm lint modules/18-helm/chart -f modules/18-helm/values-prod.yaml --strict
```

```
==> Linting modules/18-helm/chart
[INFO] Chart.yaml: icon is recommended

1 chart(s) linted, 0 chart(s) failed
```

`lint` renders the chart with the given values and checks the result for
structural problems; `--strict` turns warnings into errors (good for CI).

### 3. Render locally with `helm template`

```bash
helm template hello modules/18-helm/chart -n lab-helm | less
helm template hello modules/18-helm/chart -n lab-helm --show-only templates/deployment.yaml
```

```yaml
# Source: webapp/templates/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hello-webapp
  namespace: lab-helm
  labels:
    app: hello-webapp
    app.kubernetes.io/name: webapp
    app.kubernetes.io/instance: hello
    helm.sh/chart: webapp-0.1.0
    app.kubernetes.io/version: "1.27-alpine"
    app.kubernetes.io/managed-by: Helm
spec:
  replicas: 2
  ...
      annotations:
        checksum/config: 529ad8543d886418a4500cb411767585dc2acf7f68774a1a0c73fb3000110a67
  ...
          image: "nginx:1.27-alpine"
```

`template` needs no cluster at all. It's the quickest way to see what a
values change does. Now break the values on purpose - the schema catches it:

```bash
helm template hello modules/18-helm/chart --set replicaCount=zero
helm template hello modules/18-helm/chart --set replicaCont=3
helm template hello modules/18-helm/chart --set image.tag=latest
```

```
Error: values don't meet the specifications of the schema(s) in the following chart(s):
webapp:
- at '/replicaCount': got string, want integer

Error: values don't meet the specifications of the schema(s) in the following chart(s):
webapp:
- at '': additional properties 'replicaCont' not allowed

Error: values don't meet the specifications of the schema(s) in the following chart(s):
webapp:
- at '/image/tag': 'not' failed
```

Without `"additionalProperties": false` in the schema, `replicaCont=3` would
have been accepted and silently ignored.

### 4. Dry-run against the cluster

```bash
kubectl apply -f modules/18-helm/00-namespace.yaml
helm install hello modules/18-helm/chart -n lab-helm --dry-run=server
```

```
NAME: hello
LAST DEPLOYED: Thu Oct  8 10:47:18 2026
NAMESPACE: lab-helm
STATUS: pending-install
REVISION: 1
DESCRIPTION: Dry run complete
HOOKS:
---
# Source: webapp/templates/tests/test-connection.yaml
...
# Source: webapp/templates/pre-install-migration-job.yaml
...
MANIFEST:
---
# Source: webapp/templates/serviceaccount.yaml
...
NOTES:
...
```

Unlike `template`, this talks to the API server: objects are validated
server-side (and admission runs) but nothing is stored. Note how hooks are
listed separately from the release's manifest. Add `--debug` to also see the
computed values (it's verbose).

### 5. Install

```bash
helm install hello modules/18-helm/chart -n lab-helm --wait --timeout 2m
```

```
NAME: hello
LAST DEPLOYED: Thu Oct  8 10:47:43 2026
NAMESPACE: lab-helm
STATUS: deployed
REVISION: 1
DESCRIPTION: Install complete
NOTES:
webapp "hello" is deployed (revision 1) in namespace lab-helm.

  Image:    nginx:1.27-alpine
  Replicas: 2
  Message:  Hello from Helm!

Try it:
  kubectl -n lab-helm port-forward svc/hello-webapp 8080:80
  curl http://localhost:8080/

Run the chart's tests:
  helm test hello -n lab-helm --logs
```

```bash
helm list -n lab-helm
kubectl -n lab-helm get deploy,pods,jobs
kubectl -n lab-helm logs job/hello-webapp-migrate
```

```
NAME 	NAMESPACE	REVISION	UPDATED                             	STATUS  	CHART       	APP VERSION
hello	lab-helm 	1       	2026-10-08 10:47:43.408497 +0000 UTC	deployed	webapp-0.1.0	1.27-alpine

NAME                               READY   STATUS      RESTARTS   AGE
pod/hello-webapp-c5f54c9b7-b4dgk   1/1     Running     0          2s
pod/hello-webapp-c5f54c9b7-sswv7   1/1     Running     0          2s
pod/hello-webapp-migrate-qbdbg     0/1     Completed   0          10s

NAME                             STATUS     COMPLETIONS   DURATION   AGE
job.batch/hello-webapp-migrate   Complete   1/1           8s         11s

release hello revision 1: migrating schema for app 1.27-alpine ...
migration done
```

Look at the ages: the hook Job ran **first** (10 s ago); only after it
completed did Helm create the Deployment (2 s ago). No PodSecurity warning
was printed - the chart passes `restricted`.

### 6. Test the release

```bash
helm test hello -n lab-helm --logs
```

```
TEST SUITE:     hello-webapp-test-connection
Last Started:   Thu Oct  8 10:48:01 2026
Last Completed: Thu Oct  8 10:48:05 2026
Phase:          Succeeded

POD LOGS: hello-webapp-test-connection (curl)
GET http://hello-webapp:80/
    <h1>Hello from Helm!</h1>
test passed
```

And by hand:

```bash
kubectl -n lab-helm port-forward svc/hello-webapp 8080:80
# second terminal:
curl -s localhost:8080/
```

```html
<!doctype html>
<html>
  <head><title>hello</title></head>
  <body>
    <h1>Hello from Helm!</h1>
    <p>release=hello chart=webapp-0.1.0 image=nginx:1.27-alpine</p>
  </body>
</html>
```

### 7. Upgrade with `--set`, then with a values file

```bash
helm upgrade hello modules/18-helm/chart -n lab-helm --set message="Hello again" --wait
helm get values hello -n lab-helm
```

```
Release "hello" has been upgraded. Happy Helming!
...
REVISION: 2
...
USER-SUPPLIED VALUES:
message: Hello again
```

The message lives in the ConfigMap; the checksum annotation changed, so the
Deployment rolled out new pods (`kubectl -n lab-helm rollout history deploy/hello-webapp`
shows revision 2). Now the production values:

```bash
helm upgrade hello modules/18-helm/chart -n lab-helm -f modules/18-helm/values-prod.yaml --wait
kubectl -n lab-helm get pods -o wide -l app.kubernetes.io/instance=hello
kubectl -n lab-helm get ingress
```

```
REVISION: 3
...
NAME                           READY   STATUS    RESTARTS   AGE   IP             NODE                    ...
hello-webapp-f776d55b7-5mbrf   1/1     Running   0          2s    10.244.1.104   kube-training-worker2   ...
hello-webapp-f776d55b7-5vpxf   1/1     Running   0          5s    10.244.1.102   kube-training-worker2   ...
hello-webapp-f776d55b7-pdfkx   1/1     Running   0          6s    10.244.3.100   kube-training-worker    ...

NAME           CLASS         HOSTS                 ADDRESS   PORTS   AGE
hello-webapp   lab-traefik   webapp.localtest.me             80      7s
```

Three replicas spread over both zones, and an Ingress (it only gets an
ADDRESS if module 12's Traefik controller is running - [module 12](../12-ingress-gateway/README.md)).
Now check the message: `curl` shows **"Hello from PRODUCTION"** - and
`--set message="Hello again"` from revision 2 is gone. Every upgrade starts
from the chart defaults plus *this* command's `-f`/`--set`. In real life keep
all overrides in values files under version control, so every upgrade
passes the same complete set.

### 8. History and rollback

```bash
helm history hello -n lab-helm
helm rollback hello 2 -n lab-helm --wait
helm history hello -n lab-helm
helm get values hello -n lab-helm
```

```
REVISION	UPDATED                 	STATUS    	CHART       	APP VERSION	DESCRIPTION
1       	Thu Oct  8 10:47:43 2026	superseded	webapp-0.1.0	1.27-alpine	Install complete
2       	Thu Oct  8 10:48:12 2026	superseded	webapp-0.1.0	1.27-alpine	Upgrade complete
3       	Thu Oct  8 10:48:26 2026	superseded	webapp-0.1.0	1.27-alpine	Upgrade complete
4       	Thu Oct  8 10:49:00 2026	deployed  	webapp-0.1.0	1.27-alpine	Rollback to 2

USER-SUPPLIED VALUES:
message: Hello again
```

A rollback is a **new** revision (4) with the manifests and values of
revision 2: back to 2 replicas, and the Ingress is deleted because revision
2 didn't have one.

Where all of this is stored:

```bash
kubectl -n lab-helm get secrets -l owner=helm
```

```
NAME                          TYPE                 DATA   AGE
sh.helm.release.v1.hello.v1   helm.sh/release.v1   1      2m24s
sh.helm.release.v1.hello.v2   helm.sh/release.v1   1      114s
...
```

(`--history-max`, default 10, limits how many are kept.)

### 9. A failed upgrade that rolls itself back

Deploy a typo'd image tag, with `--rollback-on-failure` (Helm 3's `--atomic`):

```bash
helm upgrade hello modules/18-helm/chart -n lab-helm --reuse-values \
  --set image.tag=1.27-alpnie --rollback-on-failure --timeout 40s
helm history hello -n lab-helm
```

```
Error: UPGRADE FAILED: release hello failed, and has been rolled back due to rollback-on-failure being set: resource Deployment/lab-helm/hello-webapp not ready. status: InProgress, message: Updated: 1/2
context deadline exceeded

5       	Thu Oct  8 10:49:09 2026	failed    	webapp-0.1.0	1.27-alpine	Upgrade "hello" failed: resource Deployment/lab-helm/hello-webapp not ready. status: InProgress, message: Updated: ...
6       	Thu Oct  8 10:49:58 2026	deployed  	webapp-0.1.0	1.27-alpine	Rollback to 4
```

`--rollback-on-failure` implies `--wait`: Helm watched the Deployment, the
new pods never became ready (ImagePullBackOff - module 16), and after the
timeout Helm rolled back automatically. Meanwhile the old pods kept serving,
because a rolling update never removes old pods before new ones are ready.
Note the pre-upgrade migration hook *did* run for revision 5 - hooks must be
safe to run again (idempotent).

### 10. Uninstall

```bash
helm uninstall hello -n lab-helm
kubectl -n lab-helm get all
```

```
release "hello" uninstalled
NAME                               READY   STATUS        RESTARTS   AGE
pod/hello-webapp-ff9b9487d-5snwj   1/1     Terminating   0          68s
pod/hello-webapp-migrate-q6dpf     0/1     Completed     0          58s
pod/hello-webapp-test-connection   0/1     Completed     0          2m7s

NAME                             STATUS     COMPLETIONS   DURATION   AGE
job.batch/hello-webapp-migrate   Complete   1/1           8s         58s
```

The release's objects and history are gone, but the **hook Job and the test
pod are left behind** - hooks aren't part of the release (their delete
policy here is `before-hook-creation` so you can read their logs). The
namespace is also left, because Helm didn't create it. `kubectl delete
namespace lab-helm` cleans up everything.

### 11. Using a public chart

Public chart hosts may be unreachable from some networks, so this part is
read-and-try. [podinfo](https://github.com/stefanprodan/podinfo) is a small
demo app whose chart is published as an OCI artifact (with cosign
signatures):

```bash
# inspect before installing - always pin a version
helm show chart  oci://ghcr.io/stefanprodan/charts/podinfo --version 6.11.0
helm show values oci://ghcr.io/stefanprodan/charts/podinfo --version 6.11.0 | less

# render it and read what it would create
helm template demo oci://ghcr.io/stefanprodan/charts/podinfo --version 6.11.0 -n lab-helm | grep -E '^kind:'

# install with a couple of overrides, check, remove
helm install demo oci://ghcr.io/stefanprodan/charts/podinfo --version 6.11.0 -n lab-helm \
  --set replicaCount=2 --set ui.message="installed with helm" --wait
helm list -n lab-helm
kubectl -n lab-helm port-forward svc/demo-podinfo 9898:9898     # open http://localhost:9898
helm uninstall demo -n lab-helm
```

The classic, non-OCI way for comparison:

```bash
helm repo add podinfo https://stefanprodan.github.io/podinfo
helm repo update
helm search repo podinfo --versions | head -5
helm search hub podinfo            # searches Artifact Hub
helm pull podinfo/podinfo --version 6.11.0 --untar   # download and read the chart source
```

## Exercises

1. **Optional PodDisruptionBudget.** Add `pdb.enabled` / `pdb.maxUnavailable`
   values and a template that creates a PDB only when enabled *and*
   `replicaCount > 1`. Don't forget the schema - what error do you get if you
   do?
   Solution: [`solutions/pdb.yaml`](solutions/pdb.yaml) (instructions in its header).

2. **The `--reuse-values` trap.** Install with `--set message=A`, then run
   `helm upgrade` with only `--set replicaCount=3`. What is the message now?
   Repeat with `--reuse-values` and with `--reset-then-reuse-values`.
   *Hint:* `helm get values hello -n lab-helm` after each step.

3. **What changes?** Before upgrading to `values-prod.yaml`, preview the
   change with
   `helm template hello modules/18-helm/chart -n lab-helm -f modules/18-helm/values-prod.yaml --skip-tests --no-hooks | kubectl diff -f -`
   (or the [helm-diff plugin](https://github.com/databus23/helm-diff)). Why
   does `helm template` need `-n lab-helm` for this to work, and what goes
   wrong without `--skip-tests --no-hooks`?
   *Hint:* the templates use `.Release.Namespace`; the test pod still exists
   from step 6, and pods are almost immutable.

4. **A post-install hook.** Add a `post-install,post-upgrade` hook Job that
   curls the Service and fails if it doesn't answer. Compare with `helm test`:
   when does each run, and what happens to the release when each fails?

5. **Package and share.** `helm package modules/18-helm/chart` creates
   `webapp-0.1.0.tgz`. Install from the archive instead of the directory.
   Stretch: run a local OCI registry (`docker run -d -p 5000:5000 registry:2`),
   `helm push webapp-0.1.0.tgz oci://localhost:5000/charts --plain-http`,
   and install from `oci://localhost:5000/charts/webapp --version 0.1.0 --plain-http`.

6. **Public chart review.** Pick a chart you might use at work. Using only
   `helm show values` and `helm template`, list every cluster-scoped object
   it creates, every image it pulls, and whether its pods would pass the
   `restricted` Pod Security level (`kubectl apply --dry-run=server` into
   `lab-helm` prints the PSA warnings).

## Cleanup

```bash
helm uninstall hello -n lab-helm 2>/dev/null; helm uninstall demo -n lab-helm 2>/dev/null
kubectl delete namespace lab-helm
helm repo remove podinfo 2>/dev/null     # if you added it
```

## Further reading

* [Helm documentation](https://helm.sh/docs/) - [Chart template guide](https://helm.sh/docs/chart_template_guide/), [Chart best practices](https://helm.sh/docs/chart_best_practices/)
* [Chart hooks](https://helm.sh/docs/topics/charts_hooks/) and [Chart tests](https://helm.sh/docs/topics/chart_tests/)
* [Values files and schema](https://helm.sh/docs/topics/charts/#schema-files)
* [Using OCI-based registries](https://helm.sh/docs/topics/registries/)
* [Helm releases and changelogs (incl. the v4.0.0 notes)](https://github.com/helm/helm/releases)
* Kubernetes docs: [Recommended labels](https://kubernetes.io/docs/concepts/overview/working-with-objects/common-labels/)
* Related: [module 17 - Kustomize](../17-kustomize/README.md), [module 15 - Security](../15-security/README.md)
