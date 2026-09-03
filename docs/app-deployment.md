# Deploying First-Party Applications

A reusable CI/CD pattern for running your own applications (Node, Java, Python,
static web, ...) next to this stack. An application is a **separate compose
project**: its own repository, its own pipeline, its own lifecycle - attached to
the stack only through the shared networks. Nothing application-specific ever
lands in this repository.

The pattern assumes Gitea as the Git server with Actions enabled server-side
([deployment.md section 8](../deployment.md)); any Actions-compatible CI
(Gitea, Forgejo, GitHub) works with the same workflow file, and GitLab CI
follows the same stages with its own syntax.

## Architecture

```
Internet -> Cloudflare (Access?) -> Tunnel -> cloudflared ── edge-net ──┐
                                                              <app> container
appdb-net (internal) -> appdb:5432  <───────────────────────────────────┘
```

- The application publishes **no host ports, ever**. `cloudflared` reaches it
  by container name: `http://<app>:<app-port>`.
- A database-backed app joins `appdb-net` and connects to `appdb:5432`
  container-to-container - never through the published Tailscale port.
- Secrets live in the CI system's UI, never in the repository or the image.
  The pipeline materializes them into a host env file that the application's
  systemd unit also uses after reboots.

## What stays identical in every application

These six invariants are the pattern. Copy them unchanged:

1. **No `ports:` in compose.** The tunnel resolves the container name.
2. **Probe-and-wait entrypoint.** The container waits for its database (TCP
   probe, infinite loop, 2s interval) and never exits at first start. On
   rootless Podman a first-start crash-loop can wedge conmon's restart
   supervision so the publish proxy never spawns - the container later looks
   Ready while the port silently does not listen
   ([deployment.md section 16](../deployment.md)).
3. **Migrate before deploy, as a separate pipeline step.** A failed migration
   stops the release; new code never runs against a half-migrated schema.
4. **Env from CI secrets.** The pipeline regenerates the env file on every
   deploy; nobody hand-edits it. Rotation = change the secret + re-run.
5. **`restart: unless-stopped` + `init: true`**, and a per-app user systemd
   unit ordered `After=` the stack unit so boot ordering holds.
6. **Protected `production` branch + merge approval is the only trust gate.**
   Workflows run what an approved merge put on the branch - so runner access
   equals deploy authority. Keep runners repo-scoped.

## What changes per application

Everything below is a placeholder. Fill it once per app; everything else in
the templates is copy-paste.

| Placeholder | Meaning | Examples |
|---|---|---|
| `<app>` | service + container + image + DB name (one short ident, `^[a-z_][a-z0-9_]{0,62}$` to match the appdb seed rule) | `okrinterim`, `todo` |
| `<app-port>` | port the process listens on **inside** the container | `3000` (node), `8080` (spring), `8000` (uvicorn), `80` (nginx) |
| `<stack-checkout>` | directory name of this stack's checkout; Podman prefixes network names with it (`podman network ls` to confirm) | `homelab` |
| `<GITEA_HOST>` | Git server base URL | `git.example.com` |
| `<owner>/<repo>` | application repository | `me/todo` |
| `<migrate-cmd>` | idempotent migration command the image must be able to run | `npx prisma migrate deploy`, `python manage.py migrate`, `alembic upgrade head`, `java -jar flyway.jar migrate` |
| `<health-path>` | unauthenticated liveness endpoint | `/api/v1/health`, `/actuator/health` |
| `<env-keys>` | every runtime env var the app reads; one CI secret + one compose pass-through each | `DATABASE_URL`, `AUTH_SECRET` |
| `<probe>` | TCP probe one-liner available in the runtime image | see language table below |

## The five repository files

### 1. `compose.yml`

```yaml
services:
  <app>:
    build: .
    image: <app>:latest
    container_name: <app>            # cloudflared resolves this on edge-net
    restart: unless-stopped
    init: true
    environment:
      # One pass-through per <env-key>; values arrive via --env-file
      - DATABASE_URL=${DATABASE_URL}
      - AUTH_SECRET=${AUTH_SECRET}
    networks: [edge-net, appdb-net]   # edge-net only, if the app has no database
    healthcheck:                      # visibility only - never gate startup on it
      test: ["CMD-SHELL", "<health-probe> http://127.0.0.1:<app-port><health-path>"]
      interval: 10s
      timeout: 5s
      retries: 5
    # ports: never
    # depends_on with a health condition: never (see invariant 2)

networks:
  edge-net:
    external: true
    name: <stack-checkout>_edge-net
  appdb-net:
    external: true
    name: <stack-checkout>_appdb-net
```

### 2. `entrypoint.sh`

Waits for the database, then `exec`s the command. Pick the probe for your
language:

```sh
#!/bin/sh
set -eu
: "${DATABASE_URL:?DATABASE_URL is required}"

# Extract host/port from DATABASE_URL (node; or parse with whatever the
# runtime ships):
DB_HOST="$(node -e 'process.stdout.write(new URL(process.env.DATABASE_URL).hostname)')"
DB_PORT="$(node -e 'process.stdout.write(new URL(process.env.DATABASE_URL).port || "5432")')"

while ! <probe>; do
  echo "waiting for postgres at ${DB_HOST}:${DB_PORT}"
  sleep 2
done

exec "$@"
```

| Language | `<probe>` |
|---|---|
| Node | `node -e "require('net').createConnection({host:process.env.DB_HOST,port:+process.env.DB_PORT}).on('connect',()=>process.exit(0)).on('error',()=>process.exit(1))"` |
| Java (alpine) | `nc -z "$DB_HOST" "$DB_PORT"` |
| Python | `python3 -c "import socket,os,sys; s=socket.create_connection((os.environ['DB_HOST'],int(os.environ['DB_PORT'])),3); sys.exit(0)" 2>/dev/null` |
| static / no DB | drop the probe entirely; the entrypoint is just `exec "$@"` |

### 3. `.gitea/workflows/deploy.yml`

```yaml
name: deploy
on:
  push:
    branches: [production]

jobs:
  deploy:
    runs-on: <runner-label>          # e.g. okr-deploy; keep runners repo-scoped
    env:
      DEPLOY_DIR: /home/<user>/apps/<app>
      COMPOSE: /home/<user>/.local/bin/podman-compose
      ENV_FILE: /home/<user>/.config/<app>/env
      REPO_HTTP: https://<GITEA_HOST>/<owner>/<repo>.git
      GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}   # repo-scoped clone token
      # --- one line per <env-key> ---
      DATABASE_URL: ${{ secrets.DATABASE_URL }}
      AUTH_SECRET: ${{ secrets.AUTH_SECRET }}
    steps:
      - name: Checkout to deploy dir
        run: |
          set -eu
          mkdir -p "$(dirname "$DEPLOY_DIR")"
          if [ ! -d "$DEPLOY_DIR/.git" ]; then
            git clone "https://oauth2:${GITHUB_TOKEN}@${REPO_HTTP#https://}" "$DEPLOY_DIR"
          fi
          cd "$DEPLOY_DIR"
          git fetch origin production
          git reset --hard origin/production

      - name: Materialize env file from secrets
        run: |
          set -eu
          install -d -m 700 "$(dirname "$ENV_FILE")"
          # one %s per <env-key>
          ( umask 177; printf 'DATABASE_URL=%s\nAUTH_SECRET=%s\n' \
              "$DATABASE_URL" "$AUTH_SECRET" > "$ENV_FILE" )

      - name: Build
        run: |
          set -eu
          cd "$DEPLOY_DIR"
          podman build -t <app>:latest -t "<app>:${GITHUB_SHA}" .

      - name: Migrate
        run: |
          set -eu
          cd "$DEPLOY_DIR"
          "$COMPOSE" --env-file "$ENV_FILE" -f compose.yml run --rm <app> <migrate-cmd>

      - name: Deploy
        run: |
          set -eu
          cd "$DEPLOY_DIR"
          "$COMPOSE" --env-file "$ENV_FILE" -f compose.yml up -d
```

### 4. `~/.config/systemd/user/<app>.service` (server side, once)

```ini
[Unit]
Description=<app>
After=<stack-unit>.service
Wants=<stack-unit>.service
StartLimitIntervalSec=600
StartLimitBurst=3

[Service]
Type=oneshot
RemainAfterExit=yes
# WorkingDirectory unquoted on purpose: systemd does not strip quotes here
WorkingDirectory=/home/<user>/apps/<app>
ExecStart="<compose-bin>" --env-file "/home/<user>/.config/<app>/env" -f "/home/<user>/apps/<app>/compose.yml" up -d
ExecStop="<compose-bin>" --env-file "/home/<user>/.config/<app>/env" -f "/home/<user>/apps/<app>/compose.yml" down
Restart=on-failure
RestartSec=10s
TimeoutStartSec=900
TimeoutStopSec=300

[Install]
WantedBy=default.target
```

`<stack-unit>` is the stack's user unit (default `localcloud.service`). Linger
must be on (`loginctl enable-linger <user>` - the installer already does it).

### 5. `.gitlab-ci.yml` (or the prod CI's syntax)

Same three stages - `build, migrate, deploy` - with variables from that CI's
UI. Keep it in the repository from day one; each system ignores the other's
file.

## Language quick reference

| Language | Runtime image | Build essentials | `<migrate-cmd>` | `<health-path>` |
|---|---|---|---|---|
| Node / Next.js | `node:<lts>-alpine` | `output: "standalone"`; copy `.next/standalone`, `.next/static`, `public`, and the migration CLI explicitly (standalone excludes them) | `npx prisma migrate deploy` / `npx drizzle-kit migrate` | `/api/health` |
| Java / Spring | `eclipse-temurin:<major>-jre-alpine` | multi-stage: gradle/maven build stage, JRE runtime; run as non-root | `flyway migrate` (or none - let the app do it) | `/actuator/health` |
| Python / Django | `python:<minor>-slim` | `pip install` into venv; gunicorn entrypoint | `python manage.py migrate` | `/healthz` (add one) |
| Python / FastAPI | `python:<minor>-slim` | same; uvicorn | `alembic upgrade head` | `/api/health` |
| Static web | `nginx:alpine` or `caddy:alpine` | `COPY` build output into the web root; no DB, no migrate step, no probe | *(omit the pipeline step)* | `/` |

Every Dockerfile follows the same rules: multi-stage, non-root runtime user,
no secrets baked in (only truly public build-time values), `HOSTNAME=0.0.0.0`,
and the migration tooling present in the runtime image so the pipeline can
`compose run --rm <app> <migrate-cmd>`.

## Setup checklist (per application, ~1 hour)

Repository (UI + copy-paste):
1. Create the repo; add the five files; fill the placeholders.
2. Settings -> Actions -> Secrets: one per `<env-key>`. DB-backed apps:
   `DATABASE_URL=postgres://<role>:<password>@appdb:5432/<app>` - host is the
   **container name**, never the host's Tailscale address.
3. Settings -> Branches: protect `production`, direct push off. Required
   approvals only if a second person exists; a solo operator merges the MR.

Server (once per app):
4. Database, if needed (the seed only runs on a fresh cluster -
   [deployment.md section 14](../deployment.md)):
   ```sh
   podman exec -it appdb psql -U <superuser> -c 'CREATE DATABASE <app> OWNER <role>'
   podman exec -it appdb psql -U <superuser> -c 'REVOKE CONNECT ON DATABASE <app> FROM PUBLIC'
   ```
5. Register a repo-scoped runner for the new repository (one act_runner
   daemon per repo; copy the unit). An org-scoped runner is the middle ground
   once the app count grows.
6. Install the `<app>.service` unit; `systemctl --user enable` (do not start -
   the first `up -d` happens in the pipeline).

Edge:
7. Cloudflare tunnel public hostname: `<app>.<domain>` -> `http://<app>:<app-port>`.
8. Access decision: apps with their own auth (OAuth login) may skip Cloudflare
   Access; admin-style UIs without auth require Access + MFA
   ([SECURITY.md](../SECURITY.md) Tier A).

First release:
9. MR `main` -> `production`, approve, merge. Watch the pipeline.
10. Verify: `podman ps | grep -w <app>` is Up; from edge-net,
    `curl http://<app>:<app-port><health-path>` returns success.
11. Baseline migrations on a pre-existing schema (e.g. `prisma migrate resolve
    --applied <init>`) before the first pipeline run, or the migrate step
    fails by design.

## What this stack does not provide

- Runners: each application registers its own (host-level trust decision -
  [SECURITY.md](../SECURITY.md)).
- Backups for application volumes: databases in `appdb` are covered by the
  nightly `appdb-dump` and restic snapshots; anything an app stores outside a
  database (uploads, caches) is that app project's own responsibility.
- Build secrets: CI secrets reach the job, not the build; only public
  build-time values (`NEXT_PUBLIC_*`-style) belong in the Dockerfile.
