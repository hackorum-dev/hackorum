# Deployment (single VPS, Docker Compose)

This is a minimal, single-host setup for running Hackorum on a VPS (e.g., Hetzner) with Docker Compose. It includes:
- Web app (Rails / Puma)
- IMAP runner (continuous)
- Postgres with WAL archiving to a local volume
- Caddy for TLS / reverse proxy
- Autoheal watchdog to restart unhealthy containers
- Local base backups + WAL retention scripts (no external storage)

## Prerequisites
- Docker + Docker Compose v2 on the VPS
- A domain pointing to the VPS (for Caddy/HTTPS)
- Enough disk for Postgres data + backups (base backups + WAL archives)

## Setup steps
1) Copy env template and fill in secrets:
   ```bash
   cp deploy/.env.example deploy/.env
   # edit deploy/.env (SECRET_KEY_BASE, IMAP creds, etc.)
   ```

2) Copy and tune Postgres config:
   ```bash
   cp deploy/postgres/postgresql.conf.example deploy/postgres/postgresql.conf
   # edit deploy/postgres/postgresql.conf to match host resources
   ```

3) Update Caddyfile domain:
   - Edit `deploy/Caddyfile` and replace `hackorum.example.com` and contact email.

4) Build and start:
   ```bash
   cd deploy
   docker compose up -d --build
   ```
   Services:
   - `web`: Rails/Puma on port 3000 (internal)
   - `imap_worker`: continuous IMAP ingest
   - `db`: Postgres 18 with WAL archiving to `/var/lib/postgresql/wal-archive`
   - `caddy`: TLS + reverse proxy on :80/:443
   - `autoheal`: restarts containers whose healthchecks fail

5) Verify:
   - Browse to your domain; or `curl -f http://localhost:3000/up` from the host (`docker compose exec web ...` inside the network).

## Environment variables (deploy/.env)
- `SECRET_KEY_BASE` (required)
- `DATABASE_URL` (defaults to local Postgres via env interpolation)
- `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB` (for the db container)
- IMAP:
  - `IMAP_USERNAME`, `IMAP_PASSWORD`, `IMAP_MAILBOX_LABEL`
  - Optional: `IMAP_HOST`, `IMAP_PORT`, `IMAP_SSL`
- Gmail OAuth (if enabled in the app):
  - `GOOGLE_CLIENT_ID`
  - `GOOGLE_CLIENT_SECRET`
  - `GOOGLE_REDIRECT_URI` (e.g., https://your-domain/auth/google_oauth2/callback)
- Rails runtime: `RAILS_ENV=production`, `RAILS_LOG_TO_STDOUT=1`, `RAILS_SERVE_STATIC_FILES=1`

## Backups (local, WAL + base backups)
Postgres is configured with `archive_mode=on` and copies WAL files into a dedicated volume (`pgwal`). Use the provided scripts to create compressed base backups and prune old WAL/base backups.

Run (from `deploy/`):
```bash
./backup/run_base_backup.sh   # creates tarred base backup under /backups
RETAIN=3 ./backup/prune_backups.sh  # keep 3 most recent base backups, prune old WAL (>14 days)
```
Recommended cadence:
- Base backup weekly (or more often if you prefer).
- Prune after each base backup.
- Monitor disk usage; adjust retention or add external storage later if needed.

## Initial archive import (mbox)
If you need to import the historical mailing list archive before running the app:

1) Start only Postgres:
   ```bash
   cd deploy
   docker compose up -d db
   ```
2) Run the importer (mount your mbox locally). Replace `/path/to/archive.mbox` with your file:
   ```bash
   docker compose run --rm \
     -e RAILS_ENV=production \
     -v /path/to/archive.mbox:/tmp/archive.mbox \
     web bundle exec ruby script/mbox_import.rb /tmp/archive.mbox
   ```
3) Link contributors (optional but recommended if you have contributor metadata):
   ```bash
   docker compose run --rm \
     -e RAILS_ENV=production \
     web bundle exec ruby script/link_contributors.rb
   ```

4) After import completes, start the rest:
   ```bash
   docker compose up -d web imap_worker caddy autoheal
   ```
   Ensure the same env in `deploy/.env` is present so the importer can connect to the DB.

## Health and watchdog
- Containers have healthchecks. `autoheal` will restart ones labeled `autoheal=true` when unhealthy.
- `restart: unless-stopped` is enabled for long-lived services.

## Deploying updates
```bash
cd deploy
docker compose pull   # if pulling from a registry later
docker compose up -d --build
```

## Notes / future improvements
- Swap local backups for remote object storage later by replacing the backup scripts with wal-g or pgbackrest.
- Add log shipping/metrics if needed; for now Docker logs go to the host.
