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
  ingress.yaml migration-job.yaml
overlays/production/   # pin images (by digest) for prod
```

## Prerequisites

- A Kubernetes cluster + `kubectl`.
- **Ingress-NGINX** controller (`ingressClassName: nginx`).
- **cert-manager** + a `ClusterIssuer` for TLS (the TLS block in `base/ingress.yaml` is
  commented until you set this up).
- **CloudNativePG operator** installed (cluster-wide):
  ```bash
  kubectl apply -f https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/main/releases/cnpg-1.24.0.yaml
  ```
- Both images built and pushed to ghcr.io (see below).

## 1. Build & push images

**web** (from `../hashbin-web`): the repo has a `Dockerfile` (nginx serving the committed
`dist/`):
```bash
docker build -t ghcr.io/blekinge/hashbin-web:1.0.0 ../hashbin-web
docker push ghcr.io/blekinge/hashbin-web:1.0.0
```

**api** (from `../hashbin-quarkus`): a **native** image. The backend now has
`quarkus-container-image-docker` wired in and the image path (`ghcr.io/blekinge/hashbin-quarkus`)
set in its `application.properties`, so the build is just:
```bash
cd ../hashbin-quarkus
export JAVA_HOME=~/.sdkman/candidates/java/21.0.9-tem   # JDK 21 required
mvn -P '!web' -Dnative -DskipTests \
    -Dquarkus.container-image.build=true -Dquarkus.container-image.push=true \
    -Dquarkus.container-image.tag=1.0.0 package
```
> The native binary is compiled in a Mandrel container (no local GraalVM needed). On
> rootless Podman add `-Dquarkus.docker.executable-name=podman
> -Dquarkus.native.container-runtime=podman`. Full notes in the backend README
> "Container image" section. Not wired into CI (native builds are heavy) — run it by hand
> or add a workflow later.

## 2. Secrets

The app needs a **shared** HMAC + JWT secret across all api pods (so signatures and JWTs
verify on any replica). Create it out-of-band (do **not** commit it). Use SOPS /
sealed-secrets / External Secrets in a real setup:
```bash
kubectl -n hashbin create secret generic hashbin-secrets \
  --from-literal=hmac-secret="$(openssl rand -hex 32)" \
  --from-literal=jwt-secret="$(openssl rand -hex 32)"
```
The **DB** credentials are not yours to manage here — CloudNativePG auto-creates the
`hashbin-db-app` Secret (`username`/`password`), which the api Deployment consumes.

> If you are migrating data from an existing Supabase Postgres, set `hmac-secret` to the
> **original HMAC secret** so previously-issued `server_signature`s keep verifying.

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

## Scaling model

- `api`: HPA on CPU (2–10). Stateless — scale freely. **The shared secret is mandatory**
  or cross-pod signature/JWT verification breaks.
- `web`: static nginx, `replicas: 2`; put a CDN in front if you want more.
- Postgres: CNPG `instances: 2` = primary + 1 replica. The **`hashbin-db-ro`** service
  load-balances reads; to actually offload reads, split a second read-only Quarkus
  datasource pointed at `-ro` (see follow-ups).

## Follow-ups (deliberately not done here)

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
