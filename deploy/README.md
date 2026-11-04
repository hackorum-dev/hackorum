# Deployment (single VPS, Docker Compose)

This is a minimal, single-host setup for running Hackorum on a VPS (e.g., Hetzner) with Docker Compose. It includes:
- Web app (Rails / Puma)
- IMAP runner (continuous)
- Postgres
- Caddy for TLS / reverse proxy
- Umami analytics (self-hosted)
- Autoheal watchdog to restart unhealthy containers
- Monthly SQL dumps (public + private split)

## Prerequisites
- Docker + Docker Compose v2 on the VPS
- A domain pointing to the VPS (for Caddy/HTTPS)
- Enough disk for Postgres data + monthly dumps

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
   - Ensure the Umami host is set to `umami.hackorum.dev` (see `deploy/Caddyfile.example`).
   - Optional: add `dumps.hackorum.dev` to serve public dumps (see `deploy/Caddyfile.example`).

4) Configure Umami analytics:
   - Set `UMAMI_APP_SECRET` and `UMAMI_HASH_SALT` in `deploy/.env`.
   - Set `UMAMI_DB_USER` and `UMAMI_DB_PASSWORD` for the dedicated Umami database user.
   - Confirm `UMAMI_DATABASE_URL` points at the shared Postgres service.

5) Build and start:
   ```bash
   cd deploy
   docker compose up -d --build
   ```
   Services:
   - `web`: Rails/Puma on port 3000 (internal)
   - `imap_worker`: continuous IMAP ingest
   - `orchestrator`: CI orchestrator (apply, push, ingest) plus the hourly commit import
  - `db`: Postgres 18
   - `caddy`: TLS + reverse proxy on :80/:443
   - `umami`: self-hosted analytics UI/API on port 3000 (internal)
   - `autoheal`: restarts containers whose healthchecks fail

   The `orchestrator` container refuses to start until its git repo is
   provisioned once - see "First-time provisioning" below (`bin/ci-repo-setup`).
   Until then it restart-loops; harmless, but check `docker compose logs orchestrator`.

6) Verify:
   - Browse to your domain; or `curl -f http://localhost:3000/up` from the host (`docker compose exec web ...` inside the network).

## Observability
- Query stats: pg_stat_statements is preloaded via the Postgres config and created on first init via `/docker-entrypoint-initdb.d/01_pg_stat_statements.sql`. For existing databases, run `CREATE EXTENSION IF NOT EXISTS pg_stat_statements;` once. PgHero is available at `/pghero` for signed-in admin users.
- Request-level profiling: rack-mini-profiler is available; in production it renders only for signed-in admin users.

## Analytics (Umami, self-hosted)
Umami runs as a separate service and uses the same Postgres container (recommended: separate database).

Initialization:
- Fresh install: the init script creates the Umami database (`UMAMI_DB`, default `umami`) on first Postgres boot.
- Existing database: create it once manually (adjust user/db if needed):
  ```bash
  docker compose exec db psql -U postgres -d postgres -c "CREATE ROLE umami LOGIN PASSWORD 'change-me';"
  docker compose exec db psql -U postgres -d postgres -c "CREATE DATABASE umami OWNER umami;"
  ```

Access:
- Add a dedicated hostname in Caddy (example in `deploy/Caddyfile.example`).
- Visit `https://umami.hackorum.dev` and log in (default `admin` / `umami`, then change the password).
- Create a website in Umami and copy the `website_id` into `UMAMI_WEBSITE_ID` in `deploy/.env`.

## Environment variables (deploy/.env)
- `SECRET_KEY_BASE` (required)
- `RAILS_MASTER_KEY` (required — see [Credentials & encryption](#credentials--encryption))
- `APP_HOST` (required — host used by Caddy and mailer URLs)
- `DATABASE_URL` (defaults to local Postgres via env interpolation)
- `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB` (for the db container)
- `HACKORUM_DATABASE_PASSWORD` (app DB password)
- Umami:
  - `UMAMI_DB` (database name for init script; default `umami`)
  - `UMAMI_DB_USER` (dedicated Umami database user)
  - `UMAMI_DB_PASSWORD` (dedicated Umami database password)
  - `UMAMI_APP_SECRET` (required, 32+ random hex chars recommended)
  - `UMAMI_HASH_SALT` (required, 32+ random hex chars recommended)
  - `UMAMI_DATABASE_URL` (defaults to local Postgres with `UMAMI_DB`)
  - `UMAMI_WEBSITE_ID` (required for client-side tracking)
  - `UMAMI_HOST` (optional override; defaults to https://umami.hackorum.dev)
- IMAP:
  - `IMAP_USERNAME`, `IMAP_PASSWORD`, `IMAP_MAILBOX_LABEL`
  - Optional: `IMAP_HOST`, `IMAP_PORT`, `IMAP_SSL`
- CI orchestrator:
  - `HACKORUM_SSH_KEY` (host path to the deploy key with push access to
    `hackorum-dev/postgres`; mounted read-only, installed 600 in the container.
    The file must exist before the service starts - some Docker versions refuse
    to create a container whose bind-mount source is missing rather than
    silently creating a directory)
  - `HACKORUM_GITHUB_TOKEN` (PAT, `actions:read` on `hackorum-dev/postgres`)
- Lineage processor:
  - `LINEAGE_API_TOKEN` (token for the lineage processor API under `/api/lineage`;
    unset disables the routes. The processor machine runs `task lineage-processor`
    with the same value in `.env.lineage`)
- Gmail OAuth (Google sign-in + per-user "send email"):
  - `GOOGLE_CLIENT_ID`
  - `GOOGLE_CLIENT_SECRET`
  - `GOOGLE_REDIRECT_URI` (e.g., https://your-domain/auth/google_oauth2/callback)
  - See [Gmail send authorization](#gmail-send-authorization) for required scope and
    Google Cloud Console publishing status.
- Transactional mail (Mailgun SMTP — used for password reset, email verification, etc.;
  user-to-thread replies go out via Gmail API, not SMTP):
  - `MAIL_DOMAIN`, `MAIL_FROM`
  - `SMTP_ADDRESS`, `SMTP_PORT`, `SMTP_DOMAIN`, `SMTP_USERNAME`, `SMTP_PASSWORD`
- Puma / job runner:
  - `WEB_CONCURRENCY` (default `3`), `RAILS_MAX_THREADS` (default `5`)
  - `SOLID_QUEUE_IN_PUMA=1` is set in `docker-compose.yml` and is required —
    `SendOutgoingMessageJob` and the every-5-min `ResetStaleSendingDraftsJob`
    run inside the `web` container's Puma process. Do not disable.
- Rails runtime: `RAILS_ENV=production`, `RAILS_LOG_TO_STDOUT=1`, `RAILS_SERVE_STATIC_FILES=1`

## Local mail server (list ingestion)
Runs `docker-mailserver` as MX for `hackorum.dev`, receiving list mail at
`receiver@hackorum.dev`. A second worker, `imap_worker_local`, ingests that
mailbox in parallel with the Gmail `imap_worker` until cutover. Dedup is by
`Message-ID`, so both workers can run at once with no duplicate messages.

### DNS
- `A   mail.hackorum.dev  → <VPS IP>`
- `MX  hackorum.dev       → mail.hackorum.dev` (priority 10)

### First-time setup
1. Set `RECEIVER_EMAIL` and `RECEIVER_PASSWORD` in `deploy/.env`.
2. Start the mailserver and create the account:
   ```bash
   cd deploy
   docker compose up -d mailserver
   docker compose exec mailserver setup email add receiver@hackorum.dev "$RECEIVER_PASSWORD"
   ```
3. (TLS) Ensure `mail.hackorum.dev` is in the Caddyfile so Caddy issues the cert
   used for port-25 STARTTLS (see `mail.env` `SSL_*`). Verify Caddy's cert path
   matches `SSL_CERT_PATH`/`SSL_KEY_PATH`:
   `docker compose exec caddy ls /data/caddy/certificates`.
4. Start the local ingester:
   ```bash
   docker compose up -d imap_worker_local
   ```

### Subscribe to the lists
Subscribe `receiver@hackorum.dev` to `pgsql-hackers`, `pgsql-bugs`,
`pgsql-committers`. The confirmation mails land in the mailbox — read them and
complete the opt-in:
```bash
docker compose exec mailserver setup email list       # confirm the account exists
docker compose exec mailserver bash -lc 'ls -la /var/mail/hackorum.dev/receiver/new'
```

### Parallel run and cutover
- Both `imap_worker` (Gmail) and `imap_worker_local` (local) run at once.
- Watch `/admin/imap_sync_states`: two rows appear (the Gmail label and `INBOX`).
  Healthy signal — the local worker ingests messages Gmail was dropping.
- Once local coverage is confirmed complete, cut over:
  ```bash
  docker compose stop imap_worker
  # unsubscribe the Gmail account from the lists, then remove the imap_worker
  # block from docker-compose.yml and redeploy.
  ```

### Spam filtering
Rspamd is enabled so junk sent to `receiver@` is still filtered, but PostgreSQL
list mail is allowlisted so it is never dropped: `rspamd/override.d/multimap.conf`
gives a large negative score to mail whose **envelope sender** domain is
`postgresql.org`/`lists.postgresql.org` **and** passes SPF (`require_symbols = "R_SPF_ALLOW"`),
so it cannot be spoofed. To confirm it fires, check the Rspamd log / headers for the
`POSTGRESQL_SPF_ALLOW` symbol on an ingested list message. To allowlist more
infrastructure, add domains to the `map` list.

### Backups
The maildir (`maildata` volume) is a spool — Postgres is the source of truth once
messages are ingested. Keep the volume as a replay safety net; it is intentionally
not part of the monthly dump rotation.

## Credentials & encryption
The app stores per-user Gmail OAuth tokens (`Identity#refresh_token`,
`Identity#access_token`) using Active Record Encryption. The encryption keys
live in `config/credentials.yml.enc` and are decrypted at boot using
`RAILS_MASTER_KEY`.

The master key MUST NOT live inside the Docker image:
- `config/master.key` is in `.gitignore` (so it isn't committed) and in
  `.dockerignore` (so a local build cannot bake it into the image).
- On the deploy host, set `RAILS_MASTER_KEY` in `deploy/.env` instead. The
  `web` and `imap_worker` services read it from `.env`.

First-time setup (run once, from a checkout with the existing master key):
```bash
bin/rails db:encryption:init
# prints three keys under "active_record_encryption:" — copy them
EDITOR=vi bin/rails credentials:edit
# paste the three keys, save, and commit the resulting credentials.yml.enc
```

Then on each deploy host, put the master key in `deploy/.env`:
```
RAILS_MASTER_KEY=<contents of config/master.key>
```

Losing `RAILS_MASTER_KEY` makes all stored OAuth tokens permanently
unreadable — the send job will mark the affected drafts as failed with
"Stored token could not be decrypted" and revoke the identity's send
authorization, forcing each user to re-consent. Back up the master key
out-of-band (password manager / secrets vault), not in this repo.

## Gmail send authorization
Reply-sending uses the Gmail API per signed-in user, not SMTP. Each user goes
through a second OAuth consent (offline access, `gmail.send` scope) before they
can send. In the Google Cloud Console for the OAuth client referenced by
`GOOGLE_CLIENT_ID`:
- Add `https://www.googleapis.com/auth/gmail.send` to the configured scopes
  (in addition to the default `email`/`profile` used for sign-in).
- Ensure the OAuth consent screen is set to **In production** (verified).
  While the app is still in **Testing**, refresh tokens for the `gmail.send`
  scope expire after 7 days, after which queued sends fail with
  `Gmail::AuthRevokedError` and the user must re-authorize.
- The send feature is gated by a DB-backed feature flag managed under
  `/admin/features` — no env var is required to enable it, but it is off by
  default for new users.

## Backups (monthly SQL dumps)
The database dumps are split into public and private data, written to a Docker volume mounted at `/dumps` inside the Postgres container:
- `public/schema-YYYY-MM.sql.gz` (full schema, no data)
- `public/public-data-YYYY-MM.sql.gz` (data, excluding private tables)
- `private/private-data-YYYY-MM.sql.gz` (data for private tables only)

The table list lives in `deploy/backup/private_tables.txt` and is used for both dumps.
`aliases` is split by row: the public dump only gets addresses seen in the archive, without the account link, the private dump adds the rest.
Dumps older than `RETENTION_DAYS` (default 365, as promised in the privacy policy) are deleted on each run.
If you enable the `dumps.hackorum.dev` site in Caddy, only `/dumps/public` is mounted read-only in the Caddy container, so private dumps remain inaccessible.

Run (from `deploy/`):
```bash
./backup/run_monthly_dumps.sh
```
Recommended cadence:
- Run monthly (or more often if you want fresher dev data).

Example crontab (runs at 02:15 on the 1st of each month):
```bash
15 2 1 * * cd /path/to/hackorum/deploy && ./backup/run_monthly_dumps.sh >> /var/log/hackorum-dumps.log 2>&1
```

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

## CI orchestrator and commit import (shared git repo)
The CI orchestrator (`bin/orchestrator`: apply, push to the fork, ingest CI
results) and commit import (history for the site's commit pages) both read the
same PostgreSQL git history, so they share one repo on one volume, `ci_repo`,
mounted at `/ci` in the `orchestrator` container and nowhere else. `web` needs
no git at all - the old `pgrepo` volume and mount are gone.

Layout:
```
/ci/repo        bare repo
  refs/remotes/postgres/*   upstream branches, plus refs/tags/* (release attribution)
  refs/heads/master         upstream master, fast-forwarded every cycle
  refs/heads/t<topic>_<n>   patch branches
  refs/hackorum-ci/*        CI result payloads
/ci/worktree    where patches get applied
```

### Remotes
Two remotes, two jobs. `postgres` is upstream (`git.postgresql.org`), read-only.
`origin` is the fork CI runs in (`hackorum-dev/postgres`, ssh, push access via
`HACKORUM_SSH_KEY`).

`refs/remotes/origin/*` does get written - git updates tracking refs
opportunistically on any fetch that touches that remote - but nothing reads it.
This is why a manual commit import must pass `--upstream-remote postgres`
explicitly: left on the script's `origin` default, `Repository#branches` would
walk the fork's `REL*` stable branches instead of upstream's, frozen at
whatever they were when the fork was created, since only `master` is ever
mirrored to `origin`. That misattributes stable-branch membership
(`commits.branches`), not release attribution - `Repository#tags` reads local
`refs/tags/REL*` directly and takes no `upstream_remote` at all, so release
attribution is unaffected either way.

### Who fetches
The orchestrator is the only process that fetches. Every cycle (60s) it fetches
upstream `master`. Once an hour it does a full `fetch --prune --tags postgres`
and then runs the commit import itself with fetching disabled - that is why
`commit_import` is no longer in `config/recurring.yml`, and why `CommitImportJob`
is not scheduled anymore (it still exists, only as the advisory lock key both
sides share).

Consequence: if the orchestrator is down, commit import stops too (see
Health below for how `/ci` shows that without reading logs).

### The mirror-refspec trap
Do not point the importer, or anything else, at a `--mirror` clone that also
holds our own branches. A mirror fetches `+refs/*:refs/*`, so a `--prune` run
would delete every patch branch along with stale upstream refs. The layout
above - our branches under plain `refs/heads`, upstream under
`refs/remotes/postgres` - is what makes one repo safe for both jobs.

### First-time provisioning
```bash
cd deploy
docker compose run --rm orchestrator bin/ci-repo-setup
```
One-time, a few hundred MB, a few minutes for the upstream fetch. Idempotent,
so re-running it later is also the recovery procedure below.

It is not run automatically on container boot on purpose: the first fetch
easily outlasts the healthcheck's `start_period` (300s), so `autoheal` would
kill the daemon mid-fetch and restart it into the same fetch forever. Instead
`bin/orchestrator-entrypoint` checks the repo before starting `bin/orchestrator`
- git dir exists, both remotes configured, `refs/heads/master` resolves - and
refuses to start with the fix command in the error if any check fails. If the
orchestrator container is restart-looping, `docker compose logs orchestrator`
tells you exactly which check failed and prints this same command.

Re-running `bin/ci-repo-setup` resets every local patch branch (`refs/heads/t*`)
to whatever the fork currently has. That is what you want after losing the
volume; it is harmless the rest of the time, since the orchestrator always
force-pushes its own branches, and a branch it can no longer find locally just
gets re-applied on the next cycle.

Before provisioning against a live host, validate the compose file itself:
`docker compose config` is the real check, and the `prod-boot` CI workflow now
runs it on every push, but a local edit is only as good as the last time you
ran it by hand.

### Recovery from a broken or lost volume
```bash
docker compose stop orchestrator
docker volume rm deploy_ci_repo   # check the real name first: docker volume ls
docker compose run --rm orchestrator bin/ci-repo-setup
docker compose up -d orchestrator
```

`ci_repo` is deliberately not part of any backup - everything in it is
re-derivable from upstream plus the fork, which is exactly what
`bin/ci-repo-setup` does, the same posture as the `maildata` spool volume (see
Backups above). It does grow, though: the bare repo, the apply worktree, and
thousands of patch branches all live on this one volume with no pruning beyond
what result-ref retention and branch supersession already retire. Watch its
disk usage like any other named volume - the Logging section below only covers
container log rotation, not volume growth.

To pause the orchestrator for a maintenance window, or before touching
`/ci/repo` by hand, without the permanence of the cutover's "stop it for
good": `docker compose stop orchestrator`, then `docker compose start
orchestrator` (or `up -d`) when done - `restart: unless-stopped` will not
bring it back on its own while it is stopped like this.

### Health: heartbeat and autoheal
Every cycle touches `/tmp/orchestrator.heartbeat`, and the healthcheck fails
once that file's mtime is more than 10 minutes old; `autoheal` then restarts
the container. This exists because `PatchBranches::GitRepo#run` has no command
timeout - a fetch stalled on a dead connection leaves a live, listed process
with a frozen cycle, and a plain process-existence check would call that
healthy forever.

`/ci` shows the same thing without reading logs: its "orchestrator not
running" banner reads the `fetched_at` heartbeat on `PatchCiRepoState` (the
same one the planner uses to tell a live repo from a stale one), and goes
stale after 5 minutes.

Diagnostic gotcha: running `docker compose exec orchestrator bin/orchestrator
--once --dry-run` inside the *live* container touches this same heartbeat file,
which would mask an actually stuck daemon for another 10 minutes. For an
in-container diagnostic, override the path (`-e` sets it for the exec'd
process, a plain `VAR=val` prefix would only set it in your shell, not the
container):
```bash
docker compose exec -e HACKORUM_ORCHESTRATOR_HEARTBEAT=/tmp/diagnostic.heartbeat \
  orchestrator bin/orchestrator --once --dry-run
```
Simpler: use `docker compose run --rm` instead of `exec` - a fresh container
gets its own `/tmp`, so there is nothing to touch by accident.

The log is one line per cycle, plus one more per hour of maintenance:
```
[2026-07-28T10:09:12Z] in_flight=12 free_slots=18 pushed=4 failed=0 pruned=0 ... ingested=success:3,running:2
[2026-07-28T10:09:12Z] maintenance fetch=ok import=ok
```
Fields worth watching:
- `refs_stale=true` - the result-ref fetch or read failed, so no CI results were
  ingested this cycle. Results stop landing on the site while this holds.
  Check that `origin` is reachable from the container and that the deploy key
  still works - that fetch is what just failed.
- `fetch_failed=true` - the upstream `master` fetch failed, so the planner is
  working from a stale master.
- `mirror_error=...` - pushing the resolved master to the fork failed, so the
  fork's own master is no longer being updated.
- `free_slots=0` - either the budget (30) is genuinely full, or the GitHub
  in-flight query itself failed: on that error the cycle reports zero free
  slots rather than guessing, since treating "unknown" as "nothing running"
  would push blind into an already-saturated queue.
- `pushed=0` with a non-zero `free_slots` - there was room to push but nothing
  went out: either the planner found no candidates this cycle, or every
  candidate it found was refused by the push guard (base already applied
  elsewhere, no era image for that major, patchset touches `.github/`, etc -
  see `PatchCi::PushGuard`).
- `maintenance import=skipped(lock held)` - another commit import (the hourly
  one or a manual `script/commit_import.rb` run) already held the advisory
  lock, so this hour's import did not run.
- After 20 consecutive failed cycles the process gives up and exits, letting
  `restart: unless-stopped` take over.

If you ever see `import=skipped(lock held)` on *every* hourly line, the lock is
probably orphaned: it is session-scoped in Postgres, so a silent database
reconnect mid-import can leave the old session holding it server-side forever,
with nothing left to release it. Restarting the `orchestrator` container clears
it (the reconnect closes the old session for good).

None of these fields see the GitHub side of a push: an expired PAT, Actions
disabled on the fork, or GitHub rate limiting all look the same from here - a
push that succeeded, followed by no run ever appearing. The tell is
`patch_branches.ci_status = pushed_awaiting_ci` sitting past
`PatchCi::Config::STUCK_RUN_HOURS` (48h), at which point `StuckRunMarker` flips
it to `infra_error` with reason "no CI verdict 48h after push". Check the PAT
and the fork's Actions tab directly - the orchestrator has no visibility into
either.

### Manual commit import
Against the orchestrator container, not `web`:
```bash
docker compose exec orchestrator ruby script/commit_import.rb --no-fetch --upstream-remote postgres
```
`--no-fetch` because the orchestrator owns fetching now; a manual run should
only read what is already there. This takes the same advisory lock
(`commit_import`) as the hourly maintenance pass, so it refuses to start
(prints a message, exits non-zero) while an hourly import is running, and an
hourly tick likewise skips while a manual run is going. If you hit this, wait
for the other one to finish.

Never run a second orchestrator against the same fork (e.g. a dev instance left
running after cutover) - the advisory lock is per-database, so a dev instance
is *not* blocked by a prod one holding it, and both would push to the same
fork.

### released_in is write-once
`commits.released_in` is assigned write-once and never revisited: once a tag's
ancestry excludes a commit from the walk, that commit is done for good, even if
an older tag turns up later and should have claimed it first. This only bites
if tags become visible out of date order, e.g. a fetch that exposes old tags
late. A fresh provisioning is unaffected, since `bin/ci-repo-setup` fetches all
tags from upstream in one `fetch --tags` and the import walks them oldest-first.
If you do suspect misattribution, the fix is a full re-derivation: clear
`release_tags` and null out `released_in`/`released_at` on `commits`, then let
the next hourly run reassign everything from scratch.
```bash
docker compose exec orchestrator bin/rails runner '
  ReleaseTag.delete_all
  Commit.update_all(released_in: nil, released_at: nil)
'
```

### Cutover (one-time)
Dev has been running the orchestrator against the shared fork; prod has not.
This is a one-time dump-and-restore of the CI tables, not a re-run against a
fresh prod repo: `CiCommitBuilder` is deterministic, so a fresh start on prod
would re-push identical shas, GitHub would start no new runs for a no-op ref
update, and every row would sit in `pushed_awaiting_ci` until it timed out into
`infra_error`.

Steps marked Dev run on the dev machine, from the hackorum repo root, with no
container wrapper - unlike the rest of this document. `./postgres` there is
the local PostgreSQL git checkout (`bin/orchestrator`'s default `--repo`), not
the `postgres` remote name used earlier in this section. Steps marked Prod run
from `deploy/` on the VPS.

1. Dev: `ruby script/backfill_pg_major.rb` - `pg_major` is only backfilled
   where the repo is, and prod has no repo yet.
2. Dev: stop the orchestrator, for good. Dev has no long-running orchestrator
   service to disable in the first place - `task orchestrator` is a foreground
   `docker compose run --rm ... bin/orchestrator` one-shot (the `orchestrator`
   target in `Taskfile.yml`), not a daemon. Concretely: kill any `task
   orchestrator` still running in a terminal, and from here on never invoke
   `task orchestrator` again without `-- --dry-run`. There is nothing else to
   turn off. This matters because the advisory lock is per database, so a dev
   instance would not be blocked by prod's lock, and both push to the same
   fork.
3. Dev: `git -C postgres push origin 'refs/heads/*:refs/heads/*'` - makes the
   fork a complete copy of the local heads, which is what step 9 fetches.
   Needs push access to the fork: the same deploy key `HACKORUM_SSH_KEY`
   points at, or your own key if it has access.
4. Prod: `cd deploy && docker compose build`. Build only - `up -d --build`
   would start the orchestrator before its repo exists, and it would
   restart-loop on the entrypoint's repo check until step 9.
5. Prod: `cd deploy && docker compose run --rm web bin/rails db:migrate`, then
   confirm `patch_branches`, `patch_ci_runs` and `patch_ci_repo_states` exist
   and are empty:
   ```bash
   docker compose exec -T db psql -U postgres -d hackorum \
     -c "select count(*) from patch_branches" \
     -c "select count(*) from patch_ci_runs" \
     -c "select count(*) from patch_ci_repo_states"
   ```
6. Dev: dump the three tables, fully qualified so it cannot silently dump the
   wrong database (dev's `db` container publishes to host port 15432):
   ```bash
   PGPASSWORD=hackorum pg_dump -h localhost -p 15432 -U hackorum -d hackorum_development \
     --data-only --disable-triggers \
     -t patch_branches -t patch_ci_runs -t patch_ci_repo_states > ci-state.sql
   ```
   `--disable-triggers` is needed because `patch_branches` and `patch_ci_runs`
   reference each other (`patch_branches.latest_ci_run_id`,
   `patch_ci_runs.patch_branch_id`), and `patch_branches` also references
   itself (`superseded_by_id`) - no load order satisfies all three foreign
   keys at once, so the constraint triggers have to be off during the load.
   Data-only also emits the sequence `setval`s, so ids keep working after.
7. Dev: copy the dump to the VPS, e.g. `scp ci-state.sql
   you@vps:/path/to/hackorum/deploy/ci-state.sql` (adjust host and path).
8. Prod, as superuser (`--disable-triggers` needs it):
   ```bash
   cd deploy
   docker compose exec -T db psql -U postgres -d hackorum < ci-state.sql
   ```
   This load is not idempotent: if it fails partway (dropped connection, wrong
   file), retrying a full re-run hits primary-key conflicts on the rows
   already loaded. Recover with one statement -
   `TRUNCATE patch_ci_runs, patch_branches, patch_ci_repo_states;` (all three
   together, since the circular foreign keys make truncating any one alone
   fail) - then re-run the `psql` load above. This is safe precisely because
   step 5 confirmed the tables were empty to start with: there is nothing of
   prod's own to lose.
9. Prod: `cd deploy && docker compose run --rm orchestrator bin/ci-repo-setup`.
10. Prod:
    ```bash
    cd deploy
    docker compose run --rm orchestrator bin/orchestrator --once --dry-run
    ```
    Proves the database connection, the GitHub token (the in-flight run
    query), the deploy key and the `origin` remote (the result-ref fetch), the
    entrypoint's repo pre-flight checks, and the planner's output against the
    restored rows, all without pushing anything. It does NOT prove anything
    about the `postgres` upstream remote: with a
    `patch_ci_repo_states` row already restored (steps 6-8),
    `Orchestrator#refresh_repo_state!` returns that row and never calls
    `MasterSync`, so this dry run skips the upstream fetch, the local master
    fast-forward and the mirror push to the fork. Do not move this step
    earlier to dodge that gap - with no row yet, the dry run would do a real
    `MasterSync` and write one, and step 8's `--data-only` restore would then
    hit a primary-key conflict loading the same table. The first real cycle
    after step 11 is where the upstream fetch and the mirror push actually
    run for the first time - read its summary line's `fetch_failed=` and
    `mirror_error=` fields for those two. The local master fast-forward has no
    summary field at all; it only warns on stderr (`local master ... is not
    an ancestor of ...` or `local master update failed: ...`), so watch the
    container log, not just the one-line summary, right after cutover.
11. Prod: `cd deploy && docker compose up -d`. This recreates `web` on the new
    image (it loses the old `pgrepo` mount along the way), which restarts Puma
    and the Solid Queue supervisor running inside it - do this at low traffic,
    and expect any in-flight job to be interrupted and left to Solid Queue's
    own retry. It then starts the orchestrator for the first time. Expect a
    `new_version` backlog for whatever prod ingested by mail while the dev
    copy was frozen, held at the budget (30 in flight) until it drains. If the
    orchestrator itself restart-loops here, that is the restart-loop
    diagnostics under "First-time provisioning" above, not a reason to
    re-walk this list - `db`, `web` and the rest stay up and unaffected while
    you fix it.
12. Prod, once the first hourly maintenance line reports `import=ok`:
    `docker volume rm deploy_pgrepo`.

Once the first few prod cycles look right, delete `ci-state.sql` (dev machine
and wherever step 7 copied it to) - it holds only patch/CI bookkeeping, no
secrets, but there is no reason to keep a stale copy lying around.

## Logging
All services log to stdout/stderr, captured by Docker's `local` driver (see the
`x-logging-*` anchors in `docker-compose.yml`). The driver rotates by size and
gzip-compresses rotated files, so no container can fill the disk.

- **Verbose tier** (`caddy`, `web`): `250m` × `100` files ≈ ~2.4 GB gzipped on disk,
  roughly 3 months of history at current traffic.
- **Default tier** (everyone else): `20m` × `15` files ≈ ~30 MB. Kept tight on purpose
  so a misbehaving quiet service caps at ~300 MB instead of running away.
- Retention is **size-based**, not time-based — the "months" figures are estimates
  calibrated to current volume, not guarantees.

View logs as before: `docker compose logs -f caddy`. Confirm the driver is applied with
`docker inspect -f '{{.HostConfig.LogConfig}}' <container>`.

**Applying a logging change requires recreating the container**, not just restarting it.
`docker compose up -d` recreates containers to pick up new `logging:` config. Named
volumes (`pgdata`, `caddy_data`, `maildata`, …) are untouched; only the container's old
stdout/stderr capture file is discarded.

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
- Swap local dumps for remote object storage later if needed.
- Docker logs are bounded/compressed on the host via the `local` driver (see "Logging").
  Add log shipping/metrics (e.g. Loki, Vector) if off-host history or querying is needed.
- Reduce Caddy log volume if desired (skip health-check / static-asset lines).
