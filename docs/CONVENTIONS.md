# Repo conventions

These rules keep every module predictable, so you always know how to run,
inspect and clean up a lab. If you add a module, follow them too.

## Versions

The course targets **Kubernetes 1.37** on **kind v0.33.0** (default node image
`kindest/node:v1.37.0`) with **kubectl 1.37**. Everything used is stable API;
most of it works unchanged on several older and newer releases.

## Layout

```
modules/NN-topic/
  README.md            # the lesson: concepts, step-by-step lab, exercises, cleanup
  00-namespace.yaml    # every module owns exactly one namespace
  01-*.yaml            # manifests, numbered in the order you apply them
  02-*.yaml
  exercises/           # optional: broken or incomplete manifests to fix/finish
  solutions/           # optional: reference answers for exercises/
scenarios/<name>/      # deeper, real-world problems (multi-file, multi-pattern)
```

## Namespaces

* Each module uses the namespace `lab-<topic>` (e.g. `lab-pods`, `lab-storage`).
* Every namespaced manifest sets `metadata.namespace` explicitly, so
  `kubectl apply -f modules/NN-topic/` "just works" and never touches `default`.
* Cleanup is always one command: `kubectl delete namespace lab-<topic>`
  (plus any cluster-scoped objects the README lists, e.g. PVs, ClusterRoles,
  StorageClasses, PriorityClasses).

## Manifests

* One concern per file. Multiple objects per file only when they are tightly
  coupled (e.g. a Role and its RoleBinding).
* Every file starts with a comment block explaining what it is and what to
  look at.
* Comments explain *why*, not just *what*.
* Labels: `app: <name>` on everything, used by selectors.
* Images are pinned to a version tag (never `:latest`) and come from this list
  so the whole repo pulls only a handful of images:

| Image | Used for |
|---|---|
| `busybox:1.37` | shells, writers, init containers, one-off jobs |
| `nginx:1.27-alpine` | web servers, reverse proxies |
| `traefik/whoami:v1.10` | tiny HTTP server that prints which pod answered (Service/Ingress demos) |
| `hashicorp/http-echo:1.0` | HTTP backend with a fixed response text |
| `nicolaka/netshoot:v0.13` | network debugging toolbox (curl, dig, nc, tcpdump) |
| `curlimages/curl:8.11.1` | one-shot HTTP clients |
| `rancher/kubectl:v1.36.2` | in-cluster `kubectl` (RBAC demos, waiting on Jobs, scaling). Distroless: no shell, entrypoint is `kubectl`, runs as non-root. Newest published tag; ±1 minor version skew with the 1.37 API server is supported |
| `redis:7.4-alpine` | stateful demo workload |
| `postgres:16-alpine` | capstone database |
| `traefik:v3.7.13` | the ingress / Gateway API controller installed in module 12 |

A few manifests use a wrong or `:latest` tag **on purpose** (broken apps in
modules 03 and 16, the admission-policy demo in module 15); their comments say so.

* Resource requests/limits are set on every long-running container (small
  values — this is a laptop cluster).
* Prefer `kubectl apply -f`. Imperative commands (`kubectl run`,
  `kubectl create`, `kubectl expose`) are shown in READMEs as "quick way",
  with `--dry-run=client -o yaml` to show how to generate YAML.

## READMEs

Every module README uses the same sections:

1. **Goal** – one sentence.
2. **What you'll learn** – bullets.
3. **Concepts** – short explanations, tables, small diagrams.
4. **Files** – table of the manifests and what each one demonstrates.
5. **Lab** – numbered steps with exact commands and what you should observe.
6. **Exercises** – things to try on your own (with hints; solutions where useful).
7. **Cleanup** – exact commands.
8. **Further reading** – links to kubernetes.io docs.
