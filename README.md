# hashbin-deploy

Kubernetes (Kustomize) manifests for **hashbin** — the `api` (Quarkus, native) and the
static `web` frontend, scaled independently, plus an in-cluster HA PostgreSQL via
[CloudNativePG](https://cloudnative-pg.io).

Single-origin routing: `hashbin.net/api/*` and `hashbin.net/q/*` → `api`; everything
else → `web`. So the frontend's `config.js` stays at `apiBase: "/api"` and no CORS is
needed.

## Layout

```
base/
  namespace.yaml cnpg-cluster.yaml
  api-deployment.yaml api-service.yaml hpa.yaml pdb.yaml
  web-deployment.yaml web-service.yaml
  ingress.yaml issuer.yaml migration-job.yaml
overlays/production/kustomization.yaml   # single place that pins the image tags
scripts/update-images.sh                  # bump those pins from CI image refs
```

## Prerequisites

- A Kubernetes cluster + `kubectl`.
- A **Cilium** Ingress controller (`ingressClassName: cilium`).
- **cert-manager** with the **Simply.com DNS-01 webhook** installed (cluster infra: the
  runnerm `simply-dns-webhook`). The `Issuer` itself (`letsencrypt-simply-hashbin`) and its
  credentials are defined **in this repo** — `base/issuer.yaml` + a SealedSecret (see
  §2). TLS is enabled in `base/ingress.yaml`.
- **sealed-secrets controller** installed (cluster-wide) — the `harbor-cred` and
  `hashbin-secrets` SealedSecrets in `overlays/production/` are unpacked by it.
- **CloudNativePG operator** installed (cluster-wide):
  ```bash
  kubectl apply -f https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/main/releases/cnpg-1.24.0.yaml
  ```
- Both images built and pushed to Harbor by CI (see below).

## 1. Images

Images live in the org **Harbor** (`harbor.tools.nyx.kb.dk/blekinge/`), produced by each
repo's CI:

| image | Harbor repo | built by |
|---|---|
| api | `hashbin-backend` | native Quarkus build (Jenkinsfile) |
| web | `hashbin-web` | `Dockerfile.ci` (Node builds `src/`, nginx serves it) |

CI tags each build `<version>-<branch>-sha.<git-sha>-build.<n>`. Copy those refs straight
into `scripts/update-images.sh` (see **Update images** below) — that is the only step that
changes a running deployment.

<details>
<summary>Manual build (not the normal path)</summary>

**web** (from `../hashbin-web`) — same recipe CI uses (compiles `src/`; no prebuilt `dist/` needed):
```bash
DOCKER_BUILDKIT=1 docker build --target final \
  -f ../hashbin-web/Dockerfile.ci \
  -t harbor.tools.nyx.kb.dk/blekinge/hashbin-web:<tag> ../hashbin-web
docker push harbor.tools.nyx.kb.dk/blekinge/hashbin-web:<tag>
```

**api** (from `../hashbin-backend`) — a **native** image (JDK 21 required); the backend
has `quarkus-container-image-docker` wired in:
```bash
cd ../hashbin-backend
export JAVA_HOME=<a JDK 21>
mvn -pl hashbin-quarkus -am -P '!web' -Dnative -DskipTests \
    -Dquarkus.container-image.build=true -Dquarkus.container-image.push=true \
    -Dquarkus.container-image.group=blekinge \
    -Dquarkus.container-image.registry=harbor.tools.nyx.kb.dk \
    -Dquarkus.container-image.tag=<tag> package
```
> On rootless Podman add `-Dquarkus.docker.executable-name=podman
> -Dquarkus.native.container-runtime=podman`.
</details>

## 2. Secrets

**Harbor pull credentials** — the api/web/migrate pods pull from private Harbor, so the
`hashbin` namespace needs a `docker-registry` Secret named `harbor-cred` (referenced by
`imagePullSecrets` in each workload). This is **already committed** as a SealedSecret:

```
overlays/production/sealed-secret-harbor-cred.yaml
```

ArgoCD applies the SealedSecret and the in-cluster **sealed-secrets controller** unpacks
it into the `harbor-cred` Secret. **Prerequisite:** the controller must be installed
cluster-wide (`kubeseal` client + the matching controller/key pair the cluster was set up
with).

To **rotate** the Harbor token, re-seal with the org cert (the plaintext token never
touches disk — only the encrypted file is committed):

```bash
CERT=/home/asga/git/stash/CT/gitops/tools.sealedsecret.cert   # org sealed-secrets public cert
kubectl create secret docker-registry harbor-cred \
  -n hashbin \
  --docker-server=harbor.tools.nyx.kb.dk \
  --docker-username='robot$jenkins' \
  --docker-password='<new-token>' \
  --dry-run=client -o yaml \
| kubeseal --cert "$CERT" --format yaml \
> overlays/production/sealed-secret-harbor-cred.yaml
git commit -am "rotate harbor-cred" && git push
```

**App secrets** — the app needs a **shared** HMAC + JWT secret across all api pods (so
signatures and JWTs verify on any replica). These are **already committed** as a SealedSecret
(random values generated with `openssl rand -hex 32`, then sealed — no plaintext in git):

```
overlays/production/sealed-secret-hashbin-secrets.yaml
```

The sealed-secrets controller unpacks it into the `hashbin-secrets` Secret the api
Deployment references. To **rotate**, re-seal with freshly generated values (plaintext only
ever lives in the shell pipe, never on disk):

```bash
CERT=/home/asga/git/stash/CT/gitops/tools.sealedsecret.cert
kubectl create secret generic hashbin-secrets -n hashbin \
  --from-literal=hmac-secret="$(openssl rand -hex 32)" \
  --from-literal=jwt-secret="$(openssl rand -hex 32)" \
  --dry-run=client -o yaml \
| kubeseal --cert "$CERT" --format yaml \
> overlays/production/sealed-secret-hashbin-secrets.yaml
git commit -am "rotate app secrets" && git push
```

**TLS issuer credentials** — the namespaced `Issuer` (`base/issuer.yaml`) solves DNS-01 on
Simply.com and reads the `simply-credentials-hashbin` Secret from this namespace. That Secret
is committed as a SealedSecret (`overlays/production/sealed-secret-simply-credentials.yaml`,
keys `account-name` + `api-key`). To rotate the Simply API token, re-seal:

```bash
CERT=/home/asga/git/stash/CT/gitops/tools.sealedsecret.cert
kubectl create secret generic simply-credentials-hashbin -n hashbin \
  --from-literal=account-name='<account>' \
  --from-literal=api-key='<new-token>' \
  --dry-run=client -o yaml \
| kubeseal --cert "$CERT" --format yaml \
> overlays/production/sealed-secret-simply-credentials.yaml
git commit -am "rotate simply credentials" && git push
```

> **ACME server:** `base/issuer.yaml` points at the **production** Let's Encrypt server.
> (Staging is used only to re-test the DNS-01/Simply path without touching prod limits.)
> To reissue after switching servers, force it: `kubectl -n hashbin delete certificate hashbin-tls`.

The **DB** credentials are not yours to manage here — CloudNativePG auto-creates the
`hashbin-db-app` Secret (`username`/`password`), which the api Deployment consumes.

> If you are migrating data from an existing Supabase Postgres, re-seal `hashbin-secrets`
> with the **original HMAC secret** (put that literal value in the rotate command) so
> previously-issued `server_signature`s keep verifying.

## 2b. DNS (one manual record — no external-dns)

`hashbin.net` is hosted at **Simply.com**, which external-dns has no provider for (and the
cluster's external-dns only writes to the org's own BIND for `*.nyx.kb.dk`). So publish the
apex A record **by hand, once** at Simply:

```
hashbin.net.   A   <Cilium load-balancer EXTERNAL-IP>
```

Get the IP (Cilium's ingress data-plane Service is `cilium-envoy`):

```bash
kubectl -n kube-system get svc cilium-envoy \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}{"\n"}'
```

Notes:
- The **TLS cert does not need this record** — cert-manager solves DNS-01 by writing a
  temporary `_acme-challenge.hashbin.net` TXT via the Simply webhook, using API creds (not
  the public zone). This A record only routes *visitors* to the cluster.
- If `cilium-envoy` has no `EXTERNAL-IP`, ask the platform team for a static MetalLB/BGP
  address; it should be stable or visitors (and certs' renewal path) break on change.
- Optional: add `www.hashbin.net` → same IP and list it in the Ingress `rules`/`tls`.
- To later automate this away, see **Follow-ups → DNS automation**.

## 3. Deploy

```bash
# applies everything, including a one-shot run of the migration Job
kubectl apply -k overlays/production
kubectl -n hashbin get pods,svc,ing,cnpg -w
```

To re-run migrations later (e.g. after a schema change), delete the completed Job and
re-apply (idempotent — only the deleted Job is recreated):

```bash
kubectl -n hashbin delete job hashbin-migrate --ignore-not-found
kubectl apply -k overlays/production
```

## 4. Update images

The two pinned tags in `overlays/production/kustomization.yaml` are the **only** thing
that changes a running deployment. To roll out new CI builds, paste the image refs into
the helper (it just runs `kustomize edit set image`):

```bash
scripts/update-images.sh \
  harbor.tools.nyx.kb.dk/blekinge/hashbin-backend:<new-tag> \
  harbor.tools.nyx.kb.dk/blekinge/hashbin-web:<new-tag>

git diff                 # two `newTag:` lines should change
git commit -am "bump hashbin images" && git push
```

ArgoCD auto-syncs `master`, so the push is the deploy. To pin manually instead, just edit
the two `newTag:` lines. Verify what will ship with `kustomize build overlays/production`.

## Scaling model

- `api`: HPA on CPU (2–10). Stateless — scale freely. **The shared secret is mandatory**
  or cross-pod signature/JWT verification breaks.
- `web`: static nginx, `replicas: 2`; put a CDN in front if you want more.
- Postgres: CNPG `instances: 2` = primary + 1 replica. The **`hashbin-db-ro`** service
  load-balances reads; to actually offload reads, split a second read-only Quarkus
  datasource pointed at `-ro` (see follow-ups).

## Follow-ups (deliberately not done here)

- **DNS automation (external-dns)** — right now the `hashbin.net` A record is a manual
  entry at Simply (§2b), because external-dns has no Simply provider and the cluster's
  external-dns only manages `tools.nyx.kb.dk` (rfc2136 → org BIND). To automate, either:
  - serve as `hashbin.tools.nyx.kb.dk` → existing external-dns + the existing
    `letsencrypt-rfc2136-nyx` issuer handle A-record *and* cert automatically (then delete
    `base/issuer.yaml` + `sealed-secret-simply-credentials.yaml` and repoint the Ingress); or
  - **delegate** `hashbin.net` (NS) to the org BIND, then add the domain to external-dns
    `domainFilters` + the rfc2136 issuer and drop the in-app Simply Issuer + webhook.
  The external-dns + rfc2136 config lives in the infra repo at `apps/external-dns/tools/`
  and `infrastructure/cert-manager/tools/`; the current Simply Issuer lives here (`base/issuer.yaml`).
- **Migrations exit behavior**: the Job uses `QUARKUS_HTTP_ENABLED=false` and expects
  Quarkus to exit after Flyway runs. **Verify on your cluster.** If it lingers, add a
  Quarkus command-mode `migrate` entrypoint (I can add it) or switch the Job to the
  Flyway CLI.
- **Probes**: `/api/health` is a static 200 (doesn't check the DB). For a real
  readiness gate, add `quarkus-smallrye-health` and repoint probes to
  `/q/health/ready` + `/q/health/live`.
- **Backups**: configure CNPG `backups` (barman plugin → S3) + a ScheduledBackup.
- **Metrics / RPS autoscaling**: add `quarkus-micrometer-registry-prometheus` and a
  Prometheus-based HPA metric.
- **Edge rate limiting**: the app's rate limiter is per-pod (N× lenient at N replicas).
  Rate-limit at the Ingress or move the limiter to Redis.

## License

Released under the **Apache License, Version 2.0** — see [LICENSE](LICENSE).
Copyright 2025 Hashbin Contributors.
