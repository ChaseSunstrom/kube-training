# kubectl cheatsheet

The commands you will type every day, grouped by task. Every command on this
page was run with **kubectl v1.37** against a kind cluster running
**Kubernetes v1.37**, the version this course targets. Most commands were
also checked with kubectl v1.33; where the two versions behave differently,
the page says so. Two kinds of exception are labelled: commands that change
**nodes** were checked with `--dry-run=server` so the shared test cluster
was never changed, and `kubectl top` needs metrics-server
([module 14](../modules/14-autoscaling/README.md)), which the test cluster
didn't have.

The examples use these names, so swap in your own:

| Name | What it is |
|---|---|
| `lab-demo` | a namespace |
| `web` | a Deployment (container `nginx`) with a Service `web` on port 80 |
| `bb` | a single busybox Pod (container `bb`) |
| `kube-training-worker` | a node |

> **Read the output, not just the exit code.** Most of these commands also
> work with `-o yaml` / `-o json`, `--dry-run=client|server` and `-n <ns>` /
> `-A`.

---

## Contents

1. [Setup and shortcuts](#1-setup-and-shortcuts)
2. [Contexts and namespaces](#2-contexts-and-namespaces)
3. [Reading objects: get and describe](#3-reading-objects-get-and-describe)
4. [Output formats: jsonpath, custom-columns, sorting](#4-output-formats-jsonpath-custom-columns-sorting)
5. [Selectors: labels and fields](#5-selectors-labels-and-fields)
6. [Create, apply, diff, replace, delete](#6-create-apply-diff-replace-delete)
7. [Generate YAML with --dry-run=client -o yaml](#7-generate-yaml-with---dry-runclient--o-yaml)
8. [Edit and patch](#8-edit-and-patch)
9. [Rollouts and scaling](#9-rollouts-and-scaling)
10. [Logs](#10-logs)
11. [exec, cp, port-forward, proxy](#11-exec-cp-port-forward-proxy)
12. [Throwaway test pods](#12-throwaway-test-pods)
13. [kubectl debug](#13-kubectl-debug)
14. [Events](#14-events)
15. [top (metrics)](#15-top-metrics)
16. [RBAC checks: auth can-i, whoami, impersonation](#16-rbac-checks-auth-can-i-whoami-impersonation)
17. [Discovering the API: explain, api-resources](#17-discovering-the-api-explain-api-resources)
18. [wait](#18-wait)
19. [Labels, annotations, taints, cordon, drain](#19-labels-annotations-taints-cordon-drain)
20. [Kustomize (-k)](#20-kustomize--k)
21. [Handy one-liners](#21-handy-one-liners)

---

## 1. Setup and shortcuts

```bash
alias k=kubectl
source <(kubectl completion bash)          # zsh: source <(kubectl completion zsh)
complete -o default -F __start_kubectl k   # completion for the alias too (bash)
export do="--dry-run=client -o yaml"       # k create deploy web --image=nginx:1.27-alpine $do

kubectl version                            # client and server versions
kubectl cluster-info                       # API server and CoreDNS URLs
kubectl get --raw='/readyz?verbose'        # API server health checks, one per line
kubectl get pods -v=6                      # show the HTTP calls kubectl makes (-v=8 shows bodies too)
```

Short names: `po` pods, `deploy`, `rs`, `sts`, `ds`, `svc`, `ep`, `cm`,
`sa`, `ns`, `no` nodes, `pv`, `pvc`, `sc`, `ing`, `netpol`, `hpa`, `pdb`,
`cj` cronjobs, `crd`. You can list them all with `kubectl api-resources`.

## 2. Contexts and namespaces

```bash
kubectl config get-contexts                     # all contexts; * marks the current one
kubectl config current-context                  # kind-kube-training
kubectl config use-context kind-kube-training   # switch cluster/user
kubectl config set-context --current --namespace=lab-demo   # change the default namespace
kubectl config view --minify -o jsonpath='{..namespace}'    # what is my default namespace?
kubectl config view --minify                    # only the current context (secrets redacted)
kubectl config get-clusters; kubectl config get-users
kubectl config set-context lab --cluster=kind-kube-training --user=kind-kube-training --namespace=lab-demo
kubectl config rename-context lab my-lab
kubectl config delete-context my-lab

kubectl --context kind-kube-training get nodes  # one-off, without switching
KUBECONFIG=~/.kube/other.yaml kubectl get nodes # use a different kubeconfig file

kubectl get ns                                  # list namespaces
kubectl create namespace lab-demo
kubectl get pods -n lab-demo                    # one namespace
kubectl get pods -A                             # all namespaces (= --all-namespaces)
```

> `set-context --current --namespace` edits your kubeconfig file, so the
> change stays until you change it back. During labs, typing `-n lab-<topic>`
> each time is safer.

## 3. Reading objects: get and describe

```bash
kubectl get pods                         # NAME READY STATUS RESTARTS AGE
kubectl get pods -o wide                 # adds IP, NODE, NOMINATED NODE, READINESS GATES
kubectl get pods --show-labels           # adds a LABELS column
kubectl get pods -L app,tier             # one column per label key
kubectl get pods -o name                 # pod/bb, pod/web-...  (good for piping)
kubectl get pods --no-headers | wc -l
kubectl get deploy,rs,svc                # several kinds in one call
kubectl get all                          # pods, services, deployments, replicasets, statefulsets, jobs...
                                         # ("all" leaves out configmaps, secrets, PVCs, ingresses...)
kubectl get pods -w                      # watch for changes (Ctrl-C to stop)
kubectl get pods -w --output-watch-events   # prefix each line with ADDED/MODIFIED/DELETED
kubectl get pod bb -o yaml               # full object, status included
kubectl get pod bb -o json
kubectl get deploy web -o yaml --show-managed-fields   # include metadata.managedFields
kubectl get -f web.yaml                  # the live objects described in a file
kubectl get --raw /api/v1/namespaces/lab-demo/pods | head -c 300   # raw API call

kubectl describe pod bb                  # human summary and recent Events (read this first!)
kubectl describe pods -l app=web         # describe every match
kubectl describe deploy web
kubectl describe node kube-training-worker   # conditions, taints, capacity, "Allocated resources"
```

## 4. Output formats: jsonpath, custom-columns, sorting

```bash
# jsonpath: wrap in single quotes; strings inside in double quotes
kubectl get pods -o jsonpath='{.items[*].metadata.name}'
kubectl get pod bb -o jsonpath='{.spec.containers[*].image}'
kubectl get pod bb -o jsonpath='{.status.podIP}'
kubectl get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.nodeName}{"\t"}{.status.podIP}{"\n"}{end}'

# filters  [?(@.field=="value")]
kubectl get pods -o jsonpath='{.items[?(@.metadata.labels.app=="web")].metadata.name}'
kubectl get pod bb -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'        # True
kubectl get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}'

# keys with dots must be escaped
kubectl get cm app-config -o jsonpath='{.data.app\.properties}'

# custom-columns: HEADER:field-path, no {} needed (the leading dot is optional)
kubectl get pods -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeName,IP:.status.podIP,RESTARTS:.status.containerStatuses[0].restartCount
kubectl get pods -o custom-columns='NAME:.metadata.name,IMAGES:.spec.containers[*].image'
kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints
kubectl get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.qosClass}{"\n"}{end}'

# go-template (handy for decoding Secrets)
kubectl get secret db -o go-template='{{range $k,$v := .data}}{{$k}}={{$v | base64decode}}{{"\n"}}{{end}}'

# sorting (any jsonpath field)
kubectl get pods --sort-by=.metadata.creationTimestamp
kubectl get pods --sort-by='.status.containerStatuses[0].restartCount'
kubectl get pods -A -o wide --sort-by=.spec.nodeName
kubectl get events --sort-by=.metadata.creationTimestamp
```

## 5. Selectors: labels and fields

```bash
# label selectors (-l / --selector)
kubectl get pods -l app=web
kubectl get pods -l app!=web
kubectl get pods -l 'app=web,tier=frontend'    # AND
kubectl get pods -l 'app in (web,bb)'
kubectl get pods -l 'app notin (web)'
kubectl get pods -l tier                       # label exists
kubectl get pods -l '!tier'                    # label does not exist

# field selectors: only some fields are supported (metadata.name, metadata.namespace,
# status.phase and spec.nodeName for pods, type/reason/involvedObject.* for events, ...)
kubectl get pods --field-selector status.phase=Running
kubectl get pods --field-selector status.phase!=Running
kubectl get pods -A --field-selector spec.nodeName=kube-training-worker   # what runs on this node?
kubectl get pods --field-selector metadata.name=bb
kubectl get pods -A --field-selector status.phase=Pending
kubectl get pods -l app=web --field-selector spec.nodeName=kube-training-worker2   # combine both
```

## 6. Create, apply, diff, replace, delete

```bash
kubectl apply -f web.yaml                  # create or update (client-side apply)
kubectl apply -f dir/                      # every .yaml/.yml/.json in dir
kubectl apply -f dir/ -R                   # ... and in its subdirectories
kubectl apply -f https://raw.githubusercontent.com/kubernetes/website/main/content/en/examples/application/deployment.yaml
kubectl apply -k overlays/dev/             # Kustomize directory (section 20)
kubectl apply -f web.yaml --dry-run=server # full server validation + admission, nothing saved
kubectl apply --server-side -f web.yaml    # server-side apply (field ownership in managedFields)
kubectl apply --server-side --force-conflicts -f web.yaml   # take ownership of conflicting fields

kubectl diff -f web.yaml                   # live vs. what apply would do; exit code 1 = differences
kubectl create -f web.yaml                 # create only; AlreadyExists error if it exists
kubectl replace -f web.yaml                # full replace (object must exist)
kubectl replace --force -f web.yaml        # delete + recreate (pods get new names/IPs)

kubectl delete -f web.yaml                 # delete what the file describes
kubectl delete -f dir/ -R
kubectl delete pod bb                      # graceful: SIGTERM, then SIGKILL after terminationGracePeriodSeconds
kubectl delete pod bb --now                # grace period of 1 second
kubectl delete pod bb --wait=false         # return immediately, don't wait for it to be gone
kubectl delete pods -l app=web             # by label
kubectl delete pods --field-selector=status.phase==Failed
kubectl delete pod bb --grace-period=0 --force   # LAST RESORT: removes the API object without waiting
                                                 # for the kubelet; the container may keep running
kubectl delete deploy web --cascade=orphan # delete the Deployment but keep its ReplicaSets/pods
kubectl delete namespace lab-demo          # deletes everything inside it
```

## 7. Generate YAML with `--dry-run=client -o yaml`

Get a correct skeleton, redirect it to a file (`> file.yaml`), edit it, then
apply it. Add `-n <ns>` to put `metadata.namespace` in the output.

```bash
# Pod
kubectl run web --image=nginx:1.27-alpine --port=80 --labels=app=web --dry-run=client -o yaml
kubectl run bb --image=busybox:1.37 --restart=Never --env=MODE=dev --dry-run=client -o yaml -- sh -c 'echo hi; sleep 3600'
#   everything after "--" becomes the container's args (with --command it becomes the command)

# Deployment / Service
kubectl create deployment web --image=nginx:1.27-alpine --replicas=3 --port=80 --dry-run=client -o yaml
kubectl create service clusterip web --tcp=80:80 --dry-run=client -o yaml        # selector app=web
kubectl create service nodeport web --tcp=80:80 --node-port=30080 --dry-run=client -o yaml
kubectl create service externalname ext --external-name=example.com --dry-run=client -o yaml
kubectl expose deployment web --port=80 --target-port=80 --dry-run=client -o yaml # copies the Deployment's selector
kubectl expose deployment web --type=NodePort --port=80 --name=web-np --dry-run=client -o yaml
#   (expose reads the existing object, so the Deployment must exist)

# ConfigMap / Secret
kubectl create configmap app-config --from-literal=MODE=dev --from-file=app.properties --dry-run=client -o yaml
kubectl create configmap app-env --from-env-file=app.env --dry-run=client -o yaml
kubectl create secret generic db --from-literal=password='s3cr3t' --dry-run=client -o yaml
kubectl create secret tls web-tls --cert=tls.crt --key=tls.key --dry-run=client -o yaml
kubectl create secret docker-registry regcred --docker-server=registry.example.com \
  --docker-username=me --docker-password=pass --dry-run=client -o yaml

# Job / CronJob
kubectl create job hello --image=busybox:1.37 --dry-run=client -o yaml -- echo hello
kubectl create cronjob backup --image=busybox:1.37 --schedule='*/5 * * * *' --dry-run=client -o yaml -- date
kubectl create job backup-now --from=cronjob/backup      # run a CronJob once, right now (real object,
                                                         # owned by the CronJob: deleted along with it)

# RBAC
kubectl create serviceaccount app-sa --dry-run=client -o yaml
kubectl create role pod-reader --verb=get,list,watch --resource=pods,pods/log --dry-run=client -o yaml
kubectl create rolebinding pod-reader --role=pod-reader --serviceaccount=lab-demo:app-sa --dry-run=client -o yaml
kubectl create rolebinding view-sa --clusterrole=view --serviceaccount=lab-demo:app-sa --dry-run=client -o yaml
kubectl create clusterrole lab-node-reader --verb=get,list,watch --resource=nodes --dry-run=client -o yaml
kubectl create clusterrolebinding lab-node-reader --clusterrole=lab-node-reader --user=jane --dry-run=client -o yaml

# Networking / policy / scaling
kubectl create ingress web --class=nginx --rule='web.localhost/*=web:80' --dry-run=client -o yaml
#   "/*" gives pathType Prefix; "/" (no star) gives pathType Exact
kubectl create ingress web-tls --class=nginx --rule='web.localhost/=web:80,tls=web-tls' --dry-run=client -o yaml
kubectl create pdb web --selector=app=web --min-available=1 --dry-run=client -o yaml
kubectl create quota lab-quota --hard=pods=10,requests.cpu=2,requests.memory=2Gi --dry-run=client -o yaml
kubectl create priorityclass lab-high --value=1000 --description='lab only' --dry-run=client -o yaml
kubectl autoscale deployment web --min=2 --max=5 --cpu=70% --dry-run=client -o yaml   # autoscaling/v2 HPA
#   (kubectl 1.37 also has --memory=...; older kubectl only has --cpu-percent=70, which 1.37 still
#    accepts but marks deprecated)
kubectl create namespace lab-demo --dry-run=client -o yaml

# ServiceAccount token (real, short-lived; not YAML)
kubectl create token app-sa --duration=10m
```

**No generator for DaemonSet, StatefulSet, PVC, NetworkPolicy, LimitRange.**
Start from a Deployment and convert it, or copy from the docs or from
`kubectl explain`:

```bash
kubectl create deployment agent --image=busybox:1.37 --dry-run=client -o yaml -- sleep 3600 \
  | sed -e 's/^kind: Deployment/kind: DaemonSet/' -e '/replicas:/d' -e '/strategy:/d' > ds.yaml
```

Generated YAML contains `creationTimestamp: null`, `resources: {}` and
`status: {}`. They are harmless, but delete them when you tidy the file.

## 8. Edit and patch

```bash
kubectl edit deploy web                      # opens $KUBE_EDITOR / $EDITOR; saved = applied
KUBE_EDITOR=nano kubectl edit cm app-config

# strategic merge patch (default for built-in kinds): lists such as containers merge by "name"
kubectl patch deploy web -p '{"spec":{"replicas":2}}'
kubectl patch deploy web -p '{"spec":{"template":{"spec":{"containers":[{"name":"nginx","env":[{"name":"MODE","value":"prod"}]}]}}}}'
kubectl patch deploy web --patch-file=patch.yaml       # same, from a YAML/JSON file

# JSON merge patch (RFC 7386): lists are REPLACED whole; null deletes a key (the only type for CRDs)
kubectl patch deploy web --type=merge -p '{"spec":{"replicas":3}}'
kubectl patch svc web --type=merge -p '{"spec":{"type":"NodePort"}}'

# JSON patch (RFC 6902): explicit operations on JSON-pointer paths
kubectl patch deploy web --type=json -p '[{"op":"replace","path":"/spec/replicas","value":2}]'
kubectl patch deploy web --type=json -p '[{"op":"add","path":"/spec/template/metadata/labels/version","value":"v1"}]'
kubectl patch deploy web --type=json -p '[{"op":"remove","path":"/spec/template/spec/containers/0/env"}]'
kubectl patch pv my-pv --type=json -p '[{"op":"remove","path":"/spec/claimRef"}]'   # Released PV -> Available

# preview a patch without saving it
kubectl patch deploy web --dry-run=server -o jsonpath='{.spec.replicas}' -p '{"spec":{"replicas":5}}'

# subresources
kubectl get deploy web --subresource=scale -o jsonpath='{.spec.replicas}'
kubectl patch deploy web --subresource=scale --type=merge -p '{"spec":{"replicas":3}}'

# "set" shortcuts (each change to the pod template starts a rollout)
kubectl set image deploy/web nginx=nginx:1.27-alpine          # container=image
kubectl set env deploy/web MODE=prod                          # add or update
kubectl set env deploy/web MODE-                              # remove
kubectl set env deploy/web --list
kubectl set env deploy/web --from=configmap/app-config --prefix=CFG_
kubectl set resources deploy/web -c nginx --requests=cpu=20m,memory=32Mi --limits=memory=64Mi
kubectl set serviceaccount deploy/web app-sa
```

## 9. Rollouts and scaling

```bash
kubectl rollout status deploy/web --timeout=90s   # blocks until it is done; exit code != 0 on timeout
kubectl rollout history deploy/web
kubectl rollout history deploy/web --revision=2   # the pod template of that revision
kubectl rollout undo deploy/web                   # back to the previous revision
kubectl rollout undo deploy/web --to-revision=2
#   kubectl 1.37 warns that undo doesn't update the last-applied-configuration annotation:
#   fix the manifest in Git too, or the next "kubectl apply" brings the bad version back
kubectl rollout restart deploy/web                # new pods, same spec (e.g. to reload a ConfigMap)
kubectl rollout pause deploy/web                  # batch several changes...
kubectl set env deploy/web A=1; kubectl set env deploy/web B=2
kubectl rollout resume deploy/web                 # ...and roll them out as ONE new revision
kubectl annotate deploy/web kubernetes.io/change-cause='bump nginx' --overwrite
#   CHANGE-CAUSE in "rollout history" is copied from this annotation and carried into
#   later revisions until you change it. (--record is deprecated.)
# rollout status/history/undo/restart also work for daemonset/<name> and statefulset/<name>

kubectl scale deploy/web --replicas=5
kubectl scale deploy/web --current-replicas=5 --replicas=3   # only if it is currently 5
kubectl scale sts/redis --replicas=0                         # StatefulSets scale highest ordinal first
kubectl autoscale deploy web --min=2 --max=5 --cpu=70%        # HPA (needs metrics-server + CPU requests)
kubectl get hpa -w
```

## 10. Logs

```bash
kubectl logs bb                         # one container: no -c needed
kubectl logs multi -c app               # pick a container (init and sidecar containers too)
kubectl logs multi --all-containers --prefix
kubectl logs bb -f                      # follow
kubectl logs bb --tail=50 --timestamps
kubectl logs bb --since=10m             # or --since-time=2026-01-01T10:00:00Z
kubectl logs multi -c app --previous    # the PREVIOUS (crashed) container: use this for CrashLoopBackOff
kubectl logs deploy/web                 # one pod of the Deployment ("Found 3 pods, using pod/...")
kubectl logs deploy/web --all-pods --tail=1          # every pod of it
kubectl logs -l app=web --prefix --tail=20           # by label. NOTE: with -l the default is --tail=10
kubectl logs -l app=web -f --max-log-requests=10     # following >5 pods needs a higher limit (default 5)
kubectl logs job/hello
```

## 11. exec, cp, port-forward, proxy

```bash
kubectl exec -it bb -- sh               # interactive shell (use bash if the image has it)
kubectl exec bb -- ls /etc              # one command, no TTY
kubectl exec multi -c logger -- cat /proc/1/cmdline
kubectl exec deploy/web -- nginx -v     # picks one pod of the Deployment
kubectl exec svc/web -- hostname        # picks one pod behind the Service
echo hello | kubectl exec -i bb -- sh -c 'cat > /tmp/in.txt'    # -i forwards stdin

# cp needs "tar" inside the container (distroless images don't have it)
kubectl cp local.txt lab-demo/bb:/tmp/local.txt        # <ns>/<pod>:<path>
kubectl cp local.txt bb:/tmp/local.txt -c bb           # or -n plus -c
kubectl cp lab-demo/bb:/etc/hostname ./hostname.txt    # "tar: removing leading '/'" is harmless
kubectl cp ./dir lab-demo/bb:/tmp/dir                  # directories work too

# port-forward: localhost -> pod (through the API server; no Service type needed)
kubectl port-forward pod/bb 8080:80
kubectl port-forward deploy/web 8080:80        # picks one pod
kubectl port-forward svc/web 8080:80           # picks ONE pod behind the Service (no load balancing)
kubectl port-forward deploy/web :80            # random free local port (printed)
kubectl port-forward --address 0.0.0.0 svc/web 8080:80   # reachable from other machines too
#   svc/web 8080:http works only when the Service port is named "http"

kubectl proxy --port=8001 &                    # the API on localhost without auth headers
curl localhost:8001/api/v1/namespaces/lab-demo/services/web:80/proxy/
```

## 12. Throwaway test pods

```bash
kubectl run tmp --rm -it --restart=Never --image=busybox:1.37 -- sh      # shell, deleted on exit
kubectl run curl --rm -i --restart=Never --image=curlimages/curl:8.11.1 -- \
  curl -s -o /dev/null -w '%{http_code}\n' http://web                    # HTTP check from inside
kubectl run dns --rm -i --restart=Never --image=busybox:1.37 -- nslookup web.lab-demo.svc.cluster.local
kubectl run net --rm -i --restart=Never --image=nicolaka/netshoot:v0.13 -- dig +short web.lab-demo.svc.cluster.local
kubectl run net --rm -i --restart=Never --image=nicolaka/netshoot:v0.13 -- nc -zv -w 2 web 80
kubectl exec bb -- cat /etc/resolv.conf        # search domains, nameserver, ndots:5
```

`kubectl run -i` / `-it` (v1.37) first prints a notice that the session is
recorded in the container logs, which is harmless. It attaches only after
the container has started, so a command that finishes very fast can lose
its first lines of output. If that happens, drop `--rm -i`, then read the
output with `kubectl logs <pod>` and delete the pod. Use full names with
busybox's `nslookup`: it ignores the search domains, so
`nslookup kubernetes.default` fails with NXDOMAIN even when DNS works.

## 13. kubectl debug

Profiles: `general` (the default in kubectl v1.37), `baseline`,
`restricted`, `netadmin`, `sysadmin`. Older kubectl versions (e.g. v1.33)
default to the deprecated `legacy` profile and print a warning. Passing
`--profile=general` explicitly behaves the same on both.

```bash
# 1. Ephemeral container in a RUNNING pod (great for distroless/minimal images)
kubectl debug -it web-xxxx --image=busybox:1.37 --target=nginx --profile=general -- sh
#   --target shares the target container's process namespace: "ps" shows nginx as PID 1,
#   and its filesystem is visible under /proc/1/root/
kubectl debug web-xxxx --image=busybox:1.37 --target=nginx --container=dbg --profile=general -- ps
kubectl logs web-xxxx -c dbg               # output of a non-interactive debug container
kubectl get pod web-xxxx -o jsonpath='{.spec.ephemeralContainers[*].name}'
#   Ephemeral containers cannot be removed; they go away when the pod is deleted.

# 2. Debug a COPY of the pod (the original keeps running/crashing)
kubectl debug crashy -it --copy-to=crashy-debug --container=app --profile=general -- sh
#   replaces app's command with "sh" so you can look around a crash-looping container
kubectl debug web-xxxx -it --copy-to=web-debug --image=busybox:1.37 --share-processes --profile=general -- sh
#   adds a debug container to the copy, with a shared process namespace
kubectl debug bb --copy-to=bb-debug --set-image=bb=busybox:1.37 --profile=general   # change images ('*=img' = all)
#   Copies drop labels (so Services don't send them traffic) and probes; see --keep-labels,
#   --keep-liveness, --keep-readiness, --same-node.
#   CAVEAT (kubectl 1.37 and 1.33): a copy made with ONLY --set-image keeps the labels and
#   ownerReferences of the original, so a ReplicaSet-owned copy is deleted at once.
#   For Deployment pods, combine --set-image with --image=... or --container=... -- <cmd>.
kubectl delete pod crashy-debug web-debug  # copies are ordinary pods: clean them up

# 3. Debug a NODE: pod in the host namespaces, node's / mounted at /host
kubectl debug node/kube-training-worker -it --image=busybox:1.37 --profile=general -n lab-demo
#   inside:  ls /host/var/log/pods ;  chroot /host  (then e.g. crictl ps, journalctl -u kubelet)
#   --profile=sysadmin makes it privileged. The pod (node-debugger-...) stays: delete it afterwards.
kubectl get pods -n lab-demo | grep node-debugger
kubectl delete pod -n lab-demo node-debugger-kube-training-worker-xxxxx
```

On kind you can also get a shell on a node with
`docker exec -it kube-training-worker bash`, because each node is a container.

## 14. Events

Events are kept for 1 hour by default, so look at them soon after the problem.

```bash
kubectl events                              # current namespace, sorted by time, with (xN over T) counts
kubectl events --for pod/bb                 # one object
kubectl events --types=Warning              # only warnings
kubectl events -A --types=Warning
kubectl events -w                           # watch

kubectl get events --sort-by=.metadata.creationTimestamp    # older style; .lastTimestamp also works
kubectl get events --field-selector type=Warning
kubectl get events --field-selector involvedObject.name=bb,involvedObject.kind=Pod
kubectl get events -A --field-selector reason=BackOff
kubectl get events -o custom-columns=TIME:.lastTimestamp,TYPE:.type,REASON:.reason,OBJ:.involvedObject.name,MSG:.message
```

## 15. top (metrics)

Needs metrics-server ([module 14](../modules/14-autoscaling/README.md)).
Without it you get `error: Metrics API not available`.

```bash
kubectl top nodes
kubectl top nodes --sort-by=memory --show-capacity
kubectl top pods -A --sort-by=cpu
kubectl top pod web-xxxx --containers
kubectl top pods -l app=web --sum
```

## 16. RBAC checks: auth can-i, whoami, impersonation

```bash
kubectl auth whoami                                  # who does the API server think I am?
kubectl auth can-i create deployments -n lab-demo    # yes / no (exit code 0 / 1)
kubectl auth can-i '*' '*' --all-namespaces          # am I cluster-admin?
kubectl auth can-i get pods --subresource=log -n lab-demo   # same as: get pods/log
kubectl auth can-i list nodes                        # cluster-scoped resource

# test someone else's permissions (you need the "impersonate" permission; admins have it)
kubectl auth can-i get pods -n lab-demo --as=system:serviceaccount:lab-demo:app-sa
kubectl auth can-i --list -n lab-demo --as=system:serviceaccount:lab-demo:app-sa
kubectl auth can-i get pods -n lab-demo --as=jane --as-group=developers
kubectl auth whoami --as=system:serviceaccount:lab-demo:app-sa -o yaml   # shows the SA's groups
kubectl get secrets -n lab-demo --as=system:serviceaccount:lab-demo:app-sa  # see the real Forbidden error

kubectl get roles,rolebindings -n lab-demo -o wide   # -o wide shows the subjects
kubectl get clusterrolebindings -o wide | grep cluster-admin
kubectl describe rolebinding pod-reader -n lab-demo
kubectl auth reconcile -f rbac.yaml --dry-run=client # create/extend RBAC objects without removing rules
```

## 17. Discovering the API: explain, api-resources

```bash
kubectl explain pod.spec.containers.resources        # docs for one field, offline from the API's schema
kubectl explain deploy.spec.strategy --recursive     # the whole subtree, field names and types only
kubectl explain pvc.spec --recursive
kubectl explain pod.spec.initContainers.restartPolicy   # (that's how native sidecars work)
kubectl explain deployments --api-version=apps/v1

kubectl api-resources                                # every kind: short names, group/version, namespaced?
kubectl api-resources --namespaced=false             # cluster-scoped kinds (nodes, pv, sc, clusterroles...)
kubectl api-resources --api-group=apps
kubectl api-resources --api-group=''                 # the core ("") group
kubectl api-resources -o wide                        # adds VERBS and CATEGORIES
kubectl api-resources --verbs=list,watch --namespaced -o name
kubectl api-versions                                 # every group/version the server serves
```

## 18. wait

```bash
kubectl wait --for=condition=Ready pod/bb --timeout=60s
kubectl wait --for=condition=Ready pod -l app=web --timeout=60s
kubectl wait --for=condition=Available deploy/web --timeout=60s
kubectl wait --for=condition=complete job/hello --timeout=120s
kubectl wait --for=condition=failed job/hello --timeout=120s
kubectl wait --for=condition=Ready=false pod/bb --timeout=30s      # wait for NOT ready
kubectl wait --for=condition=Ready node --all --timeout=120s

kubectl wait --for=jsonpath='{.status.phase}'=Running pod/bb
kubectl wait --for=jsonpath='{.status.readyReplicas}'=3 deploy/web
kubectl wait --for=jsonpath='{.status.phase}'=Bound pvc/data
kubectl wait --for='jsonpath={.status.conditions[?(@.type=="Ready")].status}=True' pod/bb
kubectl wait --for=jsonpath='{.spec.nodeName}' pod/bb               # field exists (any value)

kubectl wait --for=create pod/late --timeout=60s     # wait until the object exists
kubectl wait --for=delete pod/bb --timeout=60s       # wait until it is gone
```

Gotchas:

* With a label selector, `kubectl wait` fails right away with
  `error: no matching resources found` if nothing matches yet. Use
  `--for=create` on a named object first, or a retry loop.
* `--timeout` covers the whole command, and pods are checked one after
  another. Completed pods are never `Ready`, so
  `kubectl wait --for=condition=Ready pods --all` times out in a namespace
  that has finished Job pods.
* A PVC on a `WaitForFirstConsumer` StorageClass (kind's `standard`) stays
  `Pending` until a pod uses it, so waiting for `Bound` before you create
  the pod never finishes.

## 19. Labels, annotations, taints, cordon, drain

```bash
kubectl label pod bb tier=tools
kubectl label pod bb tier=debug --overwrite          # without --overwrite: "already has a value" error
kubectl label pod bb tier-                           # remove
kubectl label pods -l app=web env=lab                # many at once (--all for every pod)
kubectl label ns lab-demo pod-security.kubernetes.io/enforce=restricted --dry-run=server
#   ^ the server dry run warns about existing pods that would violate the level
kubectl annotate deploy web owner=team-a
kubectl annotate deploy web owner-
kubectl annotate pod bb description='debug box' --overwrite

# --- the commands below change NODES (verified here with --dry-run=server only) ---
kubectl label node kube-training-worker disktype=ssd
kubectl label node kube-training-worker disktype-
kubectl taint nodes kube-training-worker dedicated=lab:NoSchedule        # add
kubectl taint nodes kube-training-worker dedicated=lab:NoSchedule-       # remove that one taint
kubectl taint nodes kube-training-worker dedicated-                      # remove every taint with this key
kubectl cordon kube-training-worker                  # unschedulable; running pods stay
kubectl uncordon kube-training-worker
kubectl drain kube-training-worker --ignore-daemonsets --delete-emptydir-data
#   cordons, then EVICTS pods (PodDisruptionBudgets are respected; it retries until --timeout)
#   --force             also delete pods no controller owns (they will NOT come back)
#   --pod-selector=app=web   only evict matching pods
#   --dry-run=server    see what would be evicted
kubectl describe node kube-training-control-plane | grep Taints
```

## 20. Kustomize (`-k`)

kubectl has Kustomize built in (v5.8 in kubectl v1.37; `kubectl version` prints it).

```bash
kubectl kustomize overlays/dev            # render to stdout (= kustomize build)
kubectl apply -k overlays/dev
kubectl diff -k overlays/dev
kubectl get -k overlays/dev               # the live objects it produces
kubectl delete -k overlays/dev
kubectl kustomize --enable-helm dir/      # allow helmCharts: in the kustomization (needs helm on PATH)
# "kustomize edit set image ..." and the other "edit" commands need the standalone kustomize binary
```

## 21. Handy one-liners

```bash
# decode a Secret value
kubectl get secret db -o jsonpath='{.data.password}' | base64 -d

# which pods are not Running/Succeeded, cluster-wide?
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded

# restart counts, highest last
kubectl get pods -A --sort-by='.status.containerStatuses[0].restartCount' | tail

# why did the last container instance die?
kubectl get pod bb -o jsonpath='{.status.containerStatuses[0].lastState.terminated}'

# who owns this pod?
kubectl get pods -o jsonpath='{range .items[*]}{.metadata.name}{": "}{.metadata.ownerReferences[0].kind}{"\n"}{end}'

# which endpoints does a Service really have? (v1 Endpoints is deprecated in 1.33+)
kubectl get endpointslices -l kubernetes.io/service-name=web -o wide

# QoS class of every pod
kubectl get pods -o custom-columns=NAME:.metadata.name,QOS:.status.qosClass

# which PV backs a PVC, and which node is it pinned to?
kubectl get pv $(kubectl get pvc data -o jsonpath='{.spec.volumeName}') -o jsonpath='{.spec.nodeAffinity}'

# dump a namespace for offline analysis
kubectl cluster-info dump --namespaces lab-demo --output-directory=./dump
```

See also: [troubleshooting.md](troubleshooting.md) (symptom → command) and
[glossary.md](glossary.md). Official reference:
<https://kubernetes.io/docs/reference/kubectl/quick-reference/>.
