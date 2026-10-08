# Module 05 – ConfigMaps & Secrets

## Goal

Keep configuration and credentials out of your container images, feed them to
pods as environment variables or files, and know exactly what happens when
that configuration changes.

## What you'll learn

* Create ConfigMaps from literals, files, env-files, directories and YAML.
* Consume them with `env`, `envFrom`, whole-volume mounts, single keys
  (`items`) and `subPath`, and which of those see live updates.
* Get config changes into running pods: `kubectl rollout restart` and the
  checksum-annotation pattern.
* Secrets: the `Opaque`, `kubernetes.io/tls` and
  `kubernetes.io/dockerconfigjson` types, `stringData`, and why base64 is not
  encryption.
* Immutable ConfigMaps and Secrets, and the versioned-name pattern.
* Projected volumes that merge a ConfigMap, a Secret, Downward API fields and a
  short-lived ServiceAccount token into one directory.
* What production clusters add on top: encryption at rest and external secret
  managers.

## Concepts

### ConfigMap vs Secret

| | ConfigMap | Secret |
|---|---|---|
| Meant for | non-sensitive config (feature flags, URLs, config files) | passwords, tokens, keys, certificates |
| Stored as | plain strings in `data` (or `binaryData`) | base64 strings in `data`; `stringData` is a write-only plain-text convenience |
| Max size | 1 MiB | 1 MiB |
| On the node | regular files | files on a **tmpfs** (RAM), never written to the node's disk |
| Protection | RBAC | RBAC (usually much tighter), optional encryption at rest |

A Secret is **not** encrypted just because it is a Secret. Base64 is an
encoding: `echo czNjcjN0 | base64 -d` is all it takes. What actually protects
a Secret:

* **RBAC.** `get`, `list` and `watch` on `secrets` all reveal values (`list`
  reveals *every* Secret in the namespace).
* **Who can create pods.** Anyone allowed to create a pod in a namespace can
  mount any Secret in that namespace and read it. "Create pods" therefore
  implies "read Secrets".
* **Encryption at rest** for etcd (see [Secrets in real life](#secrets-in-real-life)).

### Ways to create a ConfigMap

| Command | Result |
|---|---|
| `--from-literal=KEY=value` | one key per flag |
| `--from-file=path/app.properties` | key = file name, value = whole file |
| `--from-file=custom-key=path/file` | same, with a key name you choose |
| `--from-file=dir/` | one key per regular file in the directory (sub-directories are ignored) |
| `--from-env-file=ui.env` | one key per `KEY=value` line (`#` comments and blank lines skipped, quotes kept as-is) |
| YAML + `kubectl apply` | what you commit to git; generate it with `--dry-run=client -o yaml` |

### Ways to consume configuration

| Technique | Granularity | Sees updates? | Typical use |
|---|---|---|---|
| `env[].valueFrom.configMapKeyRef` / `secretKeyRef` | one key → one variable | **No**, fixed at container start | a handful of settings |
| `envFrom` (optional `prefix`) | every key → a variable | **No** | 12-factor apps configured entirely via env |
| `volumes[].configMap` / `.secret` | every key → a file | **Yes**, within about a minute | config files, certificates |
| … with `items:` | chosen keys → chosen paths | **Yes** | one file, renamed, custom mode |
| `volumeMounts[].subPath` | one file at an exact path | **No, never** | drop one file into a directory that already has files |
| `projected` volume | several sources → one directory | **Yes** (except via `subPath`) | config + secret + pod metadata + token together |

**Why volumes update and env vars don't.** Environment variables are copied
into the process when the container starts; nothing can change them later.
Volume files are written by the kubelet. It writes the new version into a
fresh timestamped directory, then atomically repoints a `..data` symlink to it,
so your app never sees a half-written file. The kubelet does this on its
periodic pod sync, so the total delay is the kubelet sync period (1 minute by
default) plus a little cache delay. In this lab it took 30–70 seconds.

**Why subPath doesn't update.** A `subPath` mount bind-mounts the single file
that existed when the container started. It never follows the `..data`
symlink, so it never sees a new version.

**Your app still has to re-read the file.** Updated files only help if the
process notices them (inotify, polling, a SIGHUP or `nginx -s reload`). If it
doesn't, restart the pods:

* `kubectl rollout restart deployment/<name>`, which stamps a
  `kubectl.kubernetes.io/restartedAt` annotation on the pod template, or
* the **checksum annotation pattern**: put a hash of the config into a pod
  template annotation (`checksum/config: <sha256>`). When the config changes,
  the hash changes, the template changes, and the Deployment rolls. Helm charts
  do this with `sha256sum`. Kustomize's `configMapGenerator` does the same job
  by putting a content hash in the ConfigMap's *name* (see
  [module 17](../17-kustomize/README.md)).

### Secret types

The `type` field tells the API server which keys must be present and tells
tools how to use the Secret.

| Type | Required keys | Created with | Used by |
|---|---|---|---|
| `Opaque` (default) | none | `kubectl create secret generic` | anything |
| `kubernetes.io/tls` | `tls.crt`, `tls.key` | `kubectl create secret tls` | Ingress/Gateway TLS, webhooks, apps |
| `kubernetes.io/dockerconfigjson` | `.dockerconfigjson` | `kubectl create secret docker-registry` | `imagePullSecrets` for private registries |
| `kubernetes.io/basic-auth` | `username` and/or `password` | YAML | some controllers |
| `kubernetes.io/ssh-auth` | `ssh-privatekey` | YAML | e.g. Git-syncing tools |
| `kubernetes.io/service-account-token` | filled in by the control plane | YAML (legacy) | long-lived SA tokens; prefer projected tokens (below) |

### Immutable ConfigMaps and Secrets

`immutable: true` makes the object's data permanent: updates to `data`,
`binaryData` or `stringData` are rejected, and so is flipping `immutable` back
to `false`. Labels and annotations can still change. The kubelet stops
watching immutable objects, which saves API-server load in big clusters. The
companion pattern is **versioned names** (`feature-flags-v1`,
`feature-flags-v2`): to change config, create a new object and point the
workload at it. That gives you a normal rolling update, and
`kubectl rollout undo` brings the old config back instantly.

### Projected volumes

A `projected` volume merges several sources into one directory:

```
/etc/bundle/
├── config/color        ← configMap   (app-config, key APP_COLOR)
├── secrets/username    ← secret      (db-creds, key username)
├── pod/name, labels …  ← downwardAPI (metadata, resource limits)
└── token               ← serviceAccountToken (audience "vault", 1h, auto-rotated)
```

`serviceAccountToken` gives you a **bound** JWT. It is tied to this pod
(it stops working when the pod is deleted), it expires, it is rotated by the
kubelet, and it carries the audience you choose, so you can hand it to an
external system (Vault, a cloud IAM, your own API) without that token also
being valid against the Kubernetes API.

### Secrets in real life

You will meet these in production. This module only names them:

* **Encryption at rest.** By default the API server stores Secrets in etcd
  base64-encoded, not encrypted. Cluster admins configure an
  `EncryptionConfiguration` on the API server, ideally with a **KMS v2**
  provider (cloud KMS, Vault), so that etcd and its backups hold ciphertext.
  Managed clusters (EKS/GKE/AKS) offer this as a setting.
* **Keeping secrets out of git**:
  * [External Secrets Operator](https://external-secrets.io/) syncs from AWS
    Secrets Manager, GCP Secret Manager, Azure Key Vault, Vault and others
    into normal Secrets.
  * [Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets): you
    commit an encrypted `SealedSecret`, and only the in-cluster controller can
    decrypt it.
  * Also common: the Secrets Store CSI Driver (mounts secrets straight from
    the external store) and SOPS (encrypted files in git, decrypted at deploy
    time).

## Files

| File | What it demonstrates |
|---|---|
| [`00-namespace.yaml`](00-namespace.yaml) | the `lab-config` namespace |
| [`01-configmap.yaml`](01-configmap.yaml) | ConfigMap in YAML with env-style and file-style keys |
| [`02-pod-env.yaml`](02-pod-env.yaml) | `configMapKeyRef`, `optional: true`, `envFrom` + `prefix`, Downward API env vars |
| [`03-pod-volume.yaml`](03-pod-volume.yaml) | whole-ConfigMap mount, single key with `items`, `subPath` (the update gotcha) |
| [`04-deployment-restart.yaml`](04-deployment-restart.yaml) | env vars don't update; `rollout restart`; `checksum/config` annotation |
| [`05-secret.yaml`](05-secret.yaml) | Opaque Secret with `data` and `stringData` |
| [`06-pod-secret.yaml`](06-pod-secret.yaml) | Secret as env var and as tmpfs files with `defaultMode` |
| [`07-immutable.yaml`](07-immutable.yaml) | immutable ConfigMap and Secret |
| [`08-projected.yaml`](08-projected.yaml) | projected volume: ConfigMap + Secret + Downward API + bound SA token |
| [`files/`](files/) | inputs for `--from-file` / `--from-env-file` |
| [`exercises/01-broken-env.yaml`](exercises/01-broken-env.yaml) | a pod that won't start (exercise 1) |
| [`solutions/`](solutions/) | reference answers for the exercises |

## Lab

Run everything from this module's folder:

```bash
cd modules/05-config-secrets
```

### 1. Create the namespace

```bash
kubectl apply -f 00-namespace.yaml
```

### 2. Create ConfigMaps the quick (imperative) way

```bash
kubectl create configmap cm-from-literals -n lab-config \
  --from-literal=APP_COLOR=red --from-literal=APP_MODE=dev

kubectl create configmap cm-from-file -n lab-config \
  --from-file=files/app.properties \
  --from-file=settings.properties=files/app.properties   # same file, custom key

kubectl create configmap cm-from-env-file -n lab-config --from-env-file=files/ui.env

kubectl create configmap cm-from-dir -n lab-config --from-file=files/

kubectl get configmaps -n lab-config
```

```
NAME               DATA   AGE
cm-from-dir        2      0s
cm-from-env-file   3      0s
cm-from-file       2      0s
cm-from-literals   2      0s
kube-root-ca.crt   1      3m11s
```

`kube-root-ca.crt` is created in every namespace automatically. It holds the
cluster CA so pods can verify the API server.

Compare `--from-file` with `--from-env-file`:

```bash
kubectl get configmap cm-from-file -n lab-config -o yaml
kubectl get configmap cm-from-env-file -n lab-config -o jsonpath='{.data}'; echo
```

```
data:
  app.properties: |
    # Used by: kubectl create configmap cm-from-file --from-file=files/app.properties
    greeting=hello from a file
    max.connections=25
  settings.properties: |
    ...
{"UI_LANGUAGE":"en","UI_THEME":"dark","UI_TITLE":"\"My App\""}
```

`--from-file` stored the whole file, comment and all, under one key.
`--from-env-file` split it into keys, dropped the comments and **kept the
quotes** in `UI_TITLE`, a classic surprise.

To get YAML you can commit instead of creating the object, add
`--dry-run=client -o yaml`:

```bash
kubectl create configmap demo -n lab-config --from-literal=KEY=value --dry-run=client -o yaml
```

### 3. Apply a ConfigMap from YAML

```bash
kubectl apply -f 01-configmap.yaml
kubectl describe configmap app-config -n lab-config
```

### 4. Consume it as environment variables

```bash
kubectl apply -f 02-pod-env.yaml
kubectl wait -n lab-config --for=condition=Ready pod/env-demo
kubectl logs -n lab-config env-demo
```

```
CFG_APP_COLOR=blue
CFG_APP_MODE=production
CFG_LOG_LEVEL=info
CFG_app.properties=greeting=hello
COLOR=blue
MODE=production
NODE_NAME=kube-training-worker
POD_NAME=env-demo
```

What happened:

* `COLOR` and `MODE` came from single keys and were renamed.
* `OPTIONAL_SETTING` is missing. Its key doesn't exist, and `optional: true`
  let the pod start anyway.
* `envFrom` imported every key with the `CFG_` prefix, including
  `app.properties`, which became a multi-line variable with a dot in its name
  (`kubectl exec -n lab-config env-demo -- printenv CFG_app.properties`).
  Current Kubernetes (including the 1.37 this course targets) accepts such
  names. Older versions skipped them with an
  `InvalidEnvironmentVariableNames` event. Either way, keep `envFrom`
  ConfigMaps to env-style keys.
* `POD_NAME` and `NODE_NAME` came from the **Downward API** (`fieldRef`).

### 5. Consume it as files

```bash
kubectl apply -f 03-pod-volume.yaml
kubectl wait -n lab-config --for=condition=Ready pod/volume-demo
kubectl exec -n lab-config volume-demo -- ls -la /etc/app /etc/app-one /etc/subpath
```

```
/etc/app:
drwxr-xr-x  2 root root 4096 ..2026_10_08_10_10_42.305967444
lrwxrwxrwx  1 root root   31 ..data -> ..2026_10_08_10_10_42.305967444
lrwxrwxrwx  1 root root   16 APP_COLOR -> ..data/APP_COLOR
lrwxrwxrwx  1 root root   15 APP_MODE -> ..data/APP_MODE
lrwxrwxrwx  1 root root   16 LOG_LEVEL -> ..data/LOG_LEVEL
lrwxrwxrwx  1 root root   21 app.properties -> ..data/app.properties

/etc/app-one:
lrwxrwxrwx  1 root root   30 ..data -> ..2026_10_08_10_10_42.65368962
lrwxrwxrwx  1 root root   29 application.properties -> ..data/application.properties

/etc/subpath:
-rw-r--r--  1 root root   58 app.properties
```

Every visible file in `/etc/app` is a symlink through `..data`, which is what
makes atomic updates possible. `/etc/app-one` contains only the key you listed
under `items`, under its new name. The `subPath` file is a plain file with no
symlink, so nothing will ever replace it.

### 6. Change the ConfigMap and watch what updates

```bash
kubectl patch configmap app-config -n lab-config --type merge \
  -p '{"data":{"APP_COLOR":"green","app.properties":"greeting=bonjour\nmax.connections=50\nfeature.dark-mode=true\n"}}'

# Poll until the mounted file changes (usually 30-90 seconds):
time until [ "$(kubectl exec -n lab-config volume-demo -- cat /etc/app/APP_COLOR)" = green ]; do sleep 5; done

kubectl exec -n lab-config volume-demo -- sh -c '
  echo "dir:     $(cat /etc/app/APP_COLOR)"
  echo "items:   $(grep greeting /etc/app-one/application.properties)"
  echo "subPath: $(grep greeting /etc/subpath/app.properties)"
  echo "env:     $COLOR"'
```

```
real    1m7.4s
dir:     green
items:   greeting=bonjour
subPath: greeting=hello
env:     blue
```

The two volume mounts updated. The `subPath` file and the environment
variable never will. Run `ls -la /etc/app` again: `..data` now points to a new
timestamped directory.

### 7. Get changes into pods that read env vars

```bash
kubectl apply -f 04-deployment-restart.yaml
kubectl rollout status -n lab-config deploy/greeter
kubectl logs -n lab-config -l app=greeter --tail=1 --prefix
```

```
[pod/greeter-7cfdf86bd-2qccj/greeter] 10:13:09 greeter-7cfdf86bd-2qccj says: Hello, v1
[pod/greeter-7cfdf86bd-s4jhk/greeter] 10:13:11 greeter-7cfdf86bd-s4jhk says: Hello, v1
```

Change the ConfigMap. The pods keep saying `v1`, no matter how long you wait:

```bash
kubectl patch configmap greeter-config -n lab-config --type merge -p '{"data":{"GREETING":"Hello, v2"}}'
kubectl logs -n lab-config -l app=greeter --tail=1 --prefix     # still v1
```

**Fix 1: restart the rollout.**

```bash
kubectl rollout restart -n lab-config deployment/greeter
kubectl rollout status -n lab-config deploy/greeter
kubectl logs -n lab-config -l app=greeter --tail=1 --prefix
```

```
[pod/greeter-5d86d4869c-82nrc/greeter] 10:13:28 greeter-5d86d4869c-82nrc says: Hello, v2
[pod/greeter-5d86d4869c-drpvx/greeter] 10:13:25 greeter-5d86d4869c-drpvx says: Hello, v2
```

(If you still see v1 lines, those are old pods that are still terminating.
Run the command again.)

**Fix 2: the checksum annotation.** Hash the ConfigMap data and write the hash
into the pod template. Tools like Helm do this for you on every deploy:

```bash
kubectl patch configmap greeter-config -n lab-config --type merge -p '{"data":{"GREETING":"Hello, v3"}}'

HASH=$(kubectl get configmap greeter-config -n lab-config -o jsonpath='{.data}' | sha256sum | cut -c1-16)
# macOS: use "shasum -a 256" instead of "sha256sum"
kubectl patch deployment greeter -n lab-config \
  -p "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"checksum/config\":\"$HASH\"}}}}}"
kubectl rollout status -n lab-config deploy/greeter
kubectl logs -n lab-config -l app=greeter --tail=1 --prefix
```

```
[pod/greeter-7cd754f589-2m6pm/greeter] 10:13:32 greeter-7cd754f589-2m6pm says: Hello, v3
[pod/greeter-7cd754f589-cnznz/greeter] 10:13:35 greeter-7cd754f589-cnznz says: Hello, v3
```

Both fixes work the same way: they change the **pod template**, which makes
the Deployment create a new ReplicaSet (`kubectl get rs -n lab-config -l app=greeter`).

### 8. Create a Secret and see that base64 is not encryption

```bash
kubectl apply -f 05-secret.yaml
kubectl get secret db-creds -n lab-config -o yaml
```

```yaml
data:
  db.conf: aG9zdD1wb3N0Z3Jlcy5sYWItY29uZmlnLnN2Yy5jbHVzdGVyLmxvY2FsCnBvcnQ9NTQzMgpzc2xtb2RlPXJlcXVpcmUK
  password: czNjcjN0LVBAc3M=
  username: YWRtaW4=
kind: Secret
metadata:
  annotations:
    kubectl.kubernetes.io/last-applied-configuration: |
      {"apiVersion":"v1","data":{"username":"YWRtaW4="},"kind":"Secret",...,"stringData":{"db.conf":"host=...","password":"s3cr3t-P@ss"},"type":"Opaque"}
type: Opaque
```

Three things to notice:

1. The `stringData` keys were encoded into `data`, and `stringData` itself is
   gone.
2. Decoding is trivial:

   ```bash
   kubectl get secret db-creds -n lab-config -o jsonpath='{.data.password}' | base64 -d; echo
   kubectl get secret db-creds -n lab-config \
     -o go-template='{{range $k,$v := .data}}{{$k}}={{$v | base64decode}}{{"\n"}}{{end}}'
   ```

3. **Gotcha:** client-side `kubectl apply` saved the whole manifest, plaintext
   `stringData` included, in the `last-applied-configuration` annotation.
   `kubectl create secret ...` and `kubectl apply --server-side` don't add that
   annotation.

`kubectl describe secret db-creds -n lab-config` shows only sizes
(`password: 11 bytes`). That is a courtesy, not a security boundary.

When you encode by hand, use `echo -n`. `echo admin | base64` gives
`YWRtaW4K`, which is `admin` plus a newline, and that is a very common cause of
"wrong password" bugs.

### 9. Consume the Secret

```bash
kubectl apply -f 06-pod-secret.yaml
kubectl wait -n lab-config --for=condition=Ready pod/secret-demo
kubectl logs -n lab-config secret-demo
kubectl exec -n lab-config secret-demo -- ls -lL /etc/db
kubectl exec -n lab-config secret-demo -- sh -c 'mount | grep /etc/db'
```

```
DB_USER=admin
-r--------    1 root     root            69 Oct  8 10:13 db.conf
-r--------    1 root     root            11 Oct  8 10:13 password
-r--------    1 root     root             5 Oct  8 10:13 username
tmpfs on /etc/db type tmpfs (ro,relatime,size=32768k,noswap)
```

The files are `0400` (`defaultMode`) and live on a tmpfs, so they are in
memory only. The tmpfs is sized to the pod's memory limit (32Mi here).

### 10. TLS and image-pull Secrets

Create a self-signed certificate, then a `kubernetes.io/tls` Secret from it:

```bash
openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
  -keyout /tmp/tls.key -out /tmp/tls.crt \
  -subj "/CN=demo.lab.local" -addext "subjectAltName=DNS:demo.lab.local"

kubectl create secret tls demo-tls -n lab-config --cert=/tmp/tls.crt --key=/tmp/tls.key
kubectl get secret demo-tls -n lab-config
```

```
NAME       TYPE                DATA   AGE
demo-tls   kubernetes.io/tls   2      0s
```

The type is enforced. Try a TLS Secret without a key:

```bash
kubectl create secret generic broken-tls -n lab-config \
  --type=kubernetes.io/tls --from-file=tls.crt=/tmp/tls.crt
```

```
error: failed to create secret Secret "broken-tls" is invalid: data[tls.key]: Required value
```

Credentials for a private registry go in a `dockerconfigjson` Secret:

```bash
kubectl create secret docker-registry regcred -n lab-config \
  --docker-server=registry.example.com --docker-username=robot \
  --docker-password='not-a-real-password' --docker-email=robot@example.com

kubectl get secret regcred -n lab-config -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d; echo
```

```
{"auths":{"registry.example.com":{"username":"robot","password":"not-a-real-password","email":"robot@example.com","auth":"cm9ib3Q6bm90LWEtcmVhbC1wYXNzd29yZA=="}}}
```

You would use it in a pod with `spec.imagePullSecrets: [{name: regcred}]`, or
attach it to a ServiceAccount so every pod using that SA gets it:
`kubectl patch serviceaccount default -n lab-config -p '{"imagePullSecrets":[{"name":"regcred"}]}'`.
(There is no private registry in this lab, so we stop here.)

### 11. Immutable config

```bash
kubectl apply -f 07-immutable.yaml
kubectl patch configmap feature-flags-v1 -n lab-config --type merge -p '{"data":{"NEW_CHECKOUT":"true"}}'
kubectl patch configmap feature-flags-v1 -n lab-config --type merge -p '{"immutable":false}'
kubectl patch secret api-key-v1 -n lab-config --type merge -p '{"stringData":{"API_KEY":"changed"}}'
kubectl label configmap feature-flags-v1 -n lab-config owner=team-a
```

```
The ConfigMap "feature-flags-v1" is invalid: data: Forbidden: field is immutable when `immutable` is set
The ConfigMap "feature-flags-v1" is invalid: immutable: Forbidden: field is immutable when `immutable` is set
The Secret "api-key-v1" is invalid: data: Forbidden: field is immutable when `immutable` is set
configmap/feature-flags-v1 labeled
```

Data is frozen, metadata isn't. The only way to change the data is to delete
the object and recreate it, or better, create `feature-flags-v2`
(exercise 4).

### 12. Projected volume

```bash
kubectl apply -f 08-projected.yaml
kubectl wait -n lab-config --for=condition=Ready pod/projected-demo
kubectl exec -n lab-config projected-demo -- sh -c '
  cd /etc/bundle
  for f in config/color secrets/username pod/name pod/namespace pod/labels pod/mem-limit; do
    echo "== $f"; cat $f; echo
  done'
```

```
== config/color
green
== secrets/username
admin
== pod/name
projected-demo
== pod/namespace
lab-config
== pod/labels
app="projected-demo"
tier="backend"
== pod/mem-limit
32
```

(`green` because you patched `app-config` in step 6.)

The default token mount is gone because we disabled it:

```bash
kubectl exec -n lab-config projected-demo -- ls /var/run/secrets/kubernetes.io/serviceaccount
```

```
ls: /var/run/secrets/kubernetes.io/serviceaccount: No such file or directory
```

Decode the payload, the middle part of the JWT, of the token we did ask for.
JWTs use unpadded base64url, so first translate the alphabet and restore the
`=` padding:

```bash
kubectl exec -n lab-config projected-demo -- sh -c '
  p=$(cut -d. -f2 /etc/bundle/token | tr "_-" "/+")
  while [ $(( ${#p} % 4 )) -ne 0 ]; do p="$p="; done
  echo "$p" | base64 -d'; echo
```

```json
{"aud":["vault"],"exp":1791458063,"iat":1791454463,"iss":"https://kubernetes.default.svc.cluster.local",
 "kubernetes.io":{"namespace":"lab-config","node":{"name":"kube-training-worker2",...},
 "pod":{"name":"projected-demo",...},"serviceaccount":{"name":"projected-demo",...}},
 "sub":"system:serviceaccount:lab-config:projected-demo"}
```

`aud` is `vault`, `exp - iat` is 3600 seconds, and the token names the exact
pod and node it was issued for. The kubelet refreshes it before it expires
(after 80% of its lifetime or 24 hours, whichever comes first).

## Exercises

1. **The pod that won't start.** Apply
   [`exercises/01-broken-env.yaml`](exercises/01-broken-env.yaml). Why is it
   stuck, and what are two ways to fix it?
   *Hint:* look at the STATUS column and the Events in `kubectl describe pod`.
   Solution: [`solutions/01-fixed-env.yaml`](solutions/01-fixed-env.yaml)
   (`CreateContainerConfigError: couldn't find key APP_COLOUR in ConfigMap lab-config/app-config`).

2. **A whole directory.** Mount `cm-from-dir` (step 2) into a busybox pod at
   `/config`. Which files appear? What would happen to a sub-directory inside
   `files/`?
   *Hint:* `kubectl run cfg --image=busybox:1.37 -n lab-config --dry-run=client -o yaml -- sleep 3600 > pod.yaml`,
   then add the `volumes`/`volumeMounts`. Sub-directories are silently skipped
   by `--from-file`.

3. **nginx with your own config.** Run `nginx:1.27-alpine` with a
   `default.conf` from a ConfigMap that listens on 8080 and answers
   `/healthz` with `ok`. Mount just that file with `subPath`. Then add
   `default_type text/plain;` to the ConfigMap. Does the running nginx pick it
   up? Why not, and what are two ways to make it?
   *Hint:* `kubectl exec ... -- wget -qSO- localhost:8080/healthz` shows the
   `Content-Type` header. Solution:
   [`solutions/03-nginx-custom-conf.yaml`](solutions/03-nginx-custom-conf.yaml).
   (subPath never updates, and nginx only reads config on start or reload.
   Either mount the whole ConfigMap as `/etc/nginx/conf.d` and run
   `nginx -s reload`, or do a `kubectl rollout restart`.)

4. **Roll config forward and back.** Write a Deployment `shop` that loads
   `feature-flags-v1` with `envFrom`. Then roll out new flags *without*
   editing the immutable object, and roll back with `kubectl rollout undo`.
   *Hint:* new name, new object, change one line in the Deployment.
   Solutions: [`solutions/04-shop-v1.yaml`](solutions/04-shop-v1.yaml),
   [`solutions/04-shop-v2.yaml`](solutions/04-shop-v2.yaml).

5. **Least-privilege Secret access.** Make it possible for the
   `projected-demo` ServiceAccount to read `db-creds`, and nothing else.
   Prove it with `kubectl auth can-i ... --as=system:serviceaccount:lab-config:projected-demo`.
   *Hint:* a Role with `resourceNames`. Why should you not grant `list`?
   Solution: [`solutions/05-secret-reader-rbac.yaml`](solutions/05-secret-reader-rbac.yaml).
   More in [module 11](../11-rbac/README.md).

6. **Secret rotation.** Change the password in `db-creds`
   (`kubectl patch secret db-creds -n lab-config --type merge -p '{"stringData":{"password":"rotated-123"}}'`)
   and time how long `/etc/db/password` in `secret-demo` takes to change
   (30–40 seconds here). Would an env var taken from the Secret (like
   `DB_USER`) change too? What does your
   application have to do so that a rotated database password actually takes
   effect without downtime?
   *Hint:* re-read the file on every new connection, or watch it with
   inotify. During rotation, the database must accept both the old and the
   new password for a while. Tools like
   [Reloader](https://github.com/stakater/Reloader) automate restarts on change.

## Cleanup

```bash
kubectl delete namespace lab-config
rm -f /tmp/tls.key /tmp/tls.crt
```

This module creates no cluster-scoped objects.

## Further reading

* [ConfigMaps](https://kubernetes.io/docs/concepts/configuration/configmap/)
* [Configure a Pod to use a ConfigMap](https://kubernetes.io/docs/tasks/configure-pod-container/configure-pod-configmap/)
* [Secrets](https://kubernetes.io/docs/concepts/configuration/secret/) and [Good practices for Secrets](https://kubernetes.io/docs/concepts/security/secrets-good-practices/)
* [Projected volumes](https://kubernetes.io/docs/concepts/storage/projected-volumes/)
* [Downward API](https://kubernetes.io/docs/concepts/workloads/pods/downward-api/)
* [ServiceAccount token volume projection](https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/#serviceaccount-token-volume-projection)
* [Encrypting confidential data at rest](https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/) and [KMS provider](https://kubernetes.io/docs/tasks/administer-cluster/kms-provider/)
* [Pull an image from a private registry](https://kubernetes.io/docs/tasks/configure-pod-container/pull-image-private-registry/)
