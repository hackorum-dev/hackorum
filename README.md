# Hackorum

Rails 8 app backed by Postgres. Use the containerised development setup below for a quick start; production deploy lives under `deploy/` with its own `README`.

Live application is available at https://hackorum.dev

## Development

Commands are run via [Task](https://taskfile.dev) (`task <name>`; run `task` with no arguments to list them). Both Docker and Podman (rootless) are supported. The Taskfile auto-detects which runtime is available (preferring Podman). Override with `ENGINE=docker` or `ENGINE=podman`.

1) Copy the sample env and adjust as needed:
```bash
cp .env.development.example .env.development
```
2) Build and start the stack (web + Postgres):
```bash
task dev
```
* App: http://localhost:3000
* Postgres: localhost:15432 (user/password: hackorum/hackorum by default)
* Emails sent by the application use `letter_opener`, will be opened by the browser automatically
* If you run into a Postgres data-dir warning, clear the old volume: `docker volume rm hackorum_db-data` (or `podman volume rm hackorum_db-data`)

Useful commands:
* Shell: `task shell`
* Rails console: `task console`
* Migrations/seeds: `task db-migrate` (or run arbitrary commands via `task shell`)
* Tests: `task test` (pass args after `--`, e.g. `task test -- spec/models`)
* Import the latest public dump from dumps.hackorum.dev in one step: `task db-import-latest` (downloads into `tmp/dumps`, recreates the dev DB, creates testadmin@example.com / password as admin)
* Import a DB dump: `task db-import SCHEMA=/path/to/schema-YYYY-MM.sql.gz PUBLIC_DATA=/path/to/public-data-YYYY-MM.sql.gz`
* If you need private data too, add `PRIVATE_DATA=/path/to/private-data-YYYY-MM.sql.gz` to the same command
* Import postgres commit history: `task commit-import` (expects a checkout in `./postgres`, override with `PG_REPO=/path/to/postgres`; extra importer args after `--`, e.g. `-- --limit 100`)
* Other targets: `task dev-detach` / `task down` / `task logs` / `task db-reset` / `task psql`

Public database dumps (schema + public data) are published at https://dumps.hackorum.dev/

### Incoming email simulator

There are two helper scripts `script/simulate_email_once.rb` and `simulate_email_stream.rb` that simulate incoming emails.
The scripts can be configured by a few environment variables, for details see the source of the scripts.

Task shortcuts:
* `task sim-email-once`
* `task sim-email-stream`

### IMAP worker

The "production" IMAP worker which pulls actual mailing list messages from an IMAP label can be also run locally.

```bash
task imap
```
Configure IMAP via `.env.development` (`IMAP_USERNAME`, `IMAP_PASSWORD`, `IMAP_MAILBOX_LABEL`, `IMAP_HOST`, `IMAP_PORT`, `IMAP_SSL`).

Host, Port and ssl settings default to the gmail imap server.

The imap worker will connect to the specified imap, fetch all messages with the given label, import them to the database, and mark them as "read" on the server.
It should point to a label subscribed to the pg-hackers list.
It can't be INBOX, it has to be a specific label.

### Email sending (dev)

Hackorum can send mailing-list replies via the Gmail API on behalf of users
who have opted in from `/settings/account` ("Authorize sending"). The send
pipeline uses the narrowly-scoped `gmail.send` OAuth scope and stores the
refresh token encrypted on the `identities` table.

Required environment variables in `.env.development`:

```
GOOGLE_CLIENT_ID=          # OAuth client id (any test project works)
GOOGLE_CLIENT_SECRET=      # OAuth client secret
HACKORUM_DEV_REPLY_TO=     # required: where outgoing replies actually go in dev
HACKORUM_OUTGOING_DOMAIN=  # optional, defaults to hackorum.local; used in Message-Id

# Active Record encryption keys (32+ char strings)
RAILS_AR_ENCRYPTION_PRIMARY_KEY=
RAILS_AR_ENCRYPTION_DETERMINISTIC_KEY=
RAILS_AR_ENCRYPTION_SALT=
```

Generate AR encryption values with `bin/rails runner 'puts SecureRandom.alphanumeric(32)'`.

**Safety guard**: in non-production, the recipient resolver refuses to send
when `HACKORUM_DEV_REPLY_TO` is unset, and refuses (raises) when its value
matches any real list's `post_address`. Always point it at a personal
mailbox you control during dev. Production uses `mailing_lists.post_address`
directly.

Drafts that get stuck in `status="sending"` for more than 10 minutes are
auto-reset to `idle` by `ResetStaleSendingDraftsJob` (recurring every 5
minutes via `solid_queue`).

Pending messages (Gmail accepted, awaiting list echo) appear with a yellow
"Pending" badge until the IMAP worker ingests the echo and `EmailIngestor`
flips them to `state="sent"`. Admins can inspect the pipeline at
`/admin/outgoing_messages`.

## Production
See `deploy/README.md` for the single-host Docker Compose deployment (Puma + Caddy + Postgres + backups).
