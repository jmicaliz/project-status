.DEFAULT_GOAL := help
SHELL := bash

STATUS_DIR := $(HOME)/.project-status
REPO := $(notdir $(patsubst %/,%,$(dir $(shell git rev-parse --path-format=absolute --git-common-dir 2>/dev/null))))

PORT ?= 8765

.PHONY: help install uninstall reinstall test validate lint check status status-init status-path dashboard serve dashboard-install dashboard-install-lan dashboard-uninstall token

help: ## Show available targets
	@grep -hE '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | awk -F ':.*## ' '{printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'

install: ## Install the plugin and merge permissions into ~/.claude/settings.json
	./install.sh

uninstall: ## Remove the plugin and only the settings install added
	./uninstall.sh

reinstall: uninstall install ## Uninstall, then install

test: ## Run hook tests
	tests/run.sh

validate: ## Validate the plugin and marketplace manifests
	claude plugin validate .

lint: ## Shellcheck all scripts (skipped if shellcheck is missing)
	@if command -v shellcheck >/dev/null; then shellcheck -s bash bin/project-status scripts/*.sh install.sh uninstall.sh tests/run.sh; else echo "shellcheck not installed, skipping"; fi
	node --check dashboard/app.js

check: lint validate test ## Lint, validate, and test

status-init: ## Create this repo's status file if missing (same path the SessionStart hook uses)
	@jq -n --arg cwd "$(CURDIR)" '{cwd: $$cwd}' | scripts/session-start.sh >/dev/null
	@echo "$(STATUS_DIR)/$(REPO).md"

status-path: ## Print this repo's status file path
	@echo "$(STATUS_DIR)/$(REPO).md"

status: ## Show this repo's status file
	@cat "$(STATUS_DIR)/$(REPO).md"

dashboard: ## Regenerate dashboard/status.json once
	scripts/generate-status.sh

serve: dashboard ## Serve the dashboard locally on PORT (default 8765), regenerating every 30s
	@while sleep 30; do scripts/generate-status.sh; done & trap "kill $$!" EXIT; \
	python3 scripts/dashboard-server.py --port $(PORT) --bind 127.0.0.1

token: ## Print the token the dashboard asks for before starting or removing a session
	@cat "$${PROJECT_STATUS_DIR:-$$HOME/.project-status}/.token" 2>/dev/null || echo "No token yet; run make serve or make dashboard-install first" >&2

dashboard-install: ## Install the 30s regeneration + web server on localhost:PORT as systemd units (Linux) or launchd agents (macOS)
	PORT=$(PORT) BIND=127.0.0.1 scripts/dashboard-service.sh install

dashboard-install-lan: ## Same as dashboard-install, but serve the whole LAN (0.0.0.0:PORT)
	PORT=$(PORT) BIND=0.0.0.0 scripts/dashboard-service.sh install

dashboard-uninstall: ## Stop and remove the dashboard services
	scripts/dashboard-service.sh uninstall
