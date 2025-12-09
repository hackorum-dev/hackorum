# Hackorum

Rails 8 app backed by Postgres. Use the Docker-based development setup below for a quick start; production deploy lives under `deploy/` with its own `README`.

Live application is available at https://hackorum.dev

## Development (Docker)
1) Copy the sample env and adjust as needed:
```bash
cp .env.development.example .env.development
```
2) Build and start the stack (web + Postgres):
```bash
docker compose -f docker-compose.dev.yml up --build
```
* App: http://localhost:3000
* Postgres: localhost:15432 (user/password: hackorum/hackorum by default)
* Emails sent by the application use `letter_opener`, will be opened by the browser automatically
* If you run into a Postgres data-dir warning, clear the old volume: `docker volume rm hackorum_db-data`

Useful commands:
* Shell: `docker compose -f docker-compose.dev.yml exec web bash`
* Rails console: `docker compose -f docker-compose.dev.yml exec web bin/rails console`
* Migrations/seeds: `docker compose -f docker-compose.dev.yml exec web bin/rails db:prepare`
* Tests: `docker compose -f docker-compose.dev.yml exec web bundle exec rspec`

Makefile shortcuts:
* `make dev` / `make dev-detach` / `make down`
* `make shell` / `make console` / `make logs`
* `make test`
* `make db-migrate` / `make db-reset`
* `make psql`

Optional IMAP worker (off by default):
```bash
docker compose -f docker-compose.dev.yml --profile imap up --build
```
Configure IMAP via `.env.development` (`IMAP_USERNAME`, `IMAP_PASSWORD`, `IMAP_MAILBOX_LABEL`, `IMAP_HOST`, `IMAP_PORT`, `IMAP_SSL`).
Shortcut: `make imap`

Host, Port and ssl settings default to the gmail imap server.

The imap worker will connect to the specified imap, fetch all messages with the given label, import them to the database, and mark them as "read" on the server.
It should point to a label subscribed to the pg-hackers list.
It can't be INBOX, it has to be a specific label.

## Production
See `deploy/README.md` for the single-host Docker Compose deployment (Puma + Caddy + Postgres + backups).
