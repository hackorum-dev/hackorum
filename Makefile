COMPOSE ?= docker compose --env-file .env.development -f docker-compose.dev.yml

.PHONY: dev dev-detach down shell console test imap logs db-migrate db-reset db-import stats psql sim-email-once sim-email-stream

dev: ## Start dev stack (foreground)
	$(COMPOSE) up --build

dev-detach: ## Start dev stack in background
	$(COMPOSE) up -d --build

dev-prod-detach: ## Start dev stack but run Rails in production mode (uses dev compose & env)
	RAILS_ENV=production NODE_ENV=production RAILS_SERVE_STATIC_FILES=1 RAILS_LOG_TO_STDOUT=1 FORCE_SSL=false $(COMPOSE) up -d --build

down: ## Stop dev stack
	$(COMPOSE) stop
	rm -f tmp/pids/server.pid

shell: ## Open a shell in the web container
	$(COMPOSE) exec web bash

console: ## Open Rails console in the web container
	$(COMPOSE) exec web bin/rails console

test: ## Run RSpec in the web container (uses test database)
	$(COMPOSE) exec -e RAILS_ENV=test -e DATABASE_URL=postgresql://hackorum:hackorum@db:5432/hackorum_test web bin/rails db:prepare
	$(COMPOSE) exec -e RAILS_ENV=test -e DATABASE_URL=postgresql://hackorum:hackorum@db:5432/hackorum_test web bundle exec rspec

db-migrate: ## Run db:migrate
	$(COMPOSE) exec web bin/rails db:migrate

db-reset: ## Drop and setup (create/migrate/seed) - stops web if running, restarts after
	@WEB_WAS_RUNNING=$$($(COMPOSE) ps --status running --format '{{.Service}}' | grep -q '^web$$' && echo 1 || echo 0); \
	if [ "$$WEB_WAS_RUNNING" = "1" ]; then \
		echo "Stopping web container..."; \
		$(COMPOSE) stop web; \
	fi; \
	echo "Running db:drop and db:setup..."; \
	$(COMPOSE) run --rm web bin/rails db:drop db:setup; \
	if [ "$$WEB_WAS_RUNNING" = "1" ]; then \
		echo "Restarting web container..."; \
		$(COMPOSE) start web; \
	fi

db-import: ## Drop dev DB and import a public dump (env: DUMP=/path/to/public-YYYY-MM.sql.gz)
	@if [ -z "$(DUMP)" ]; then echo "Set DUMP=/path/to/public-YYYY-MM.sql.gz"; exit 1; fi
	$(COMPOSE) exec -T db bash -lc 'psql -U $${POSTGRES_USER:-hackorum} -d postgres -c "DROP DATABASE IF EXISTS $${POSTGRES_DB:-hackorum_development};" -c "CREATE DATABASE $${POSTGRES_DB:-hackorum_development};"'
	@if echo "$(DUMP)" | grep -qE '\.gz$$'; then \
	  gzip -cd "$(DUMP)" | $(COMPOSE) exec -T db bash -lc 'psql -U $${POSTGRES_USER:-hackorum} -d $${POSTGRES_DB:-hackorum_development}'; \
	else \
	  cat "$(DUMP)" | $(COMPOSE) exec -T db bash -lc 'psql -U $${POSTGRES_USER:-hackorum} -d $${POSTGRES_DB:-hackorum_development}'; \
	fi

stats: ## Rebuild stats (env: GRANULARITY=all|daily|weekly|monthly)
	$(COMPOSE) exec web bundle exec ruby script/build_stats.rb $${GRANULARITY:-all}

psql: ## Open psql against the dev DB
	COMPOSE_PROFILES=tools $(COMPOSE) run --rm psql

imap: ## Start stack with IMAP worker profile
	$(COMPOSE) --profile imap up --build

logs: ## Follow web logs
	$(COMPOSE) logs -f web

sim-email-once: ## Send a single simulated email (env: SENT_OFFSET_SECONDS, EXISTING_ALIAS_PROB, EXISTING_TOPIC_PROB)
	$(COMPOSE) exec web ruby script/simulate_email_once.rb

sim-email-stream: ## Start a continuous simulated email stream (env: MIN_INTERVAL_SECONDS, MAX_INTERVAL_SECONDS, EXISTING_ALIAS_PROB, EXISTING_TOPIC_PROB)
	$(COMPOSE) exec web ruby script/simulate_email_stream.rb
