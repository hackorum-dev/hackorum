COMPOSE ?= docker compose -f docker-compose.dev.yml

.PHONY: dev dev-detach down shell console test imap logs db-migrate db-reset psql

dev: ## Start dev stack (foreground)
	$(COMPOSE) up --build

dev-detach: ## Start dev stack in background
	$(COMPOSE) up -d --build

down: ## Stop dev stack
	$(COMPOSE) down

shell: ## Open a shell in the web container
	$(COMPOSE) exec web bash

console: ## Open Rails console in the web container
	$(COMPOSE) exec web bin/rails console

test: ## Run RSpec in the web container
	$(COMPOSE) exec web bundle exec rspec

db-migrate: ## Run db:migrate
	$(COMPOSE) exec web bin/rails db:migrate

db-reset: ## Drop and prepare (create/migrate)
	$(COMPOSE) run --rm web bin/rails db:drop && bin/rails db:prepare

psql: ## Open psql against the dev DB
	COMPOSE_PROFILES=tools $(COMPOSE) run --rm psql

imap: ## Start stack with IMAP worker profile
	$(COMPOSE) --profile imap up --build

logs: ## Follow web logs
	$(COMPOSE) logs -f web
