.DEFAULT_GOAL := help
.SILENT:
.PHONY: help install install-no-models uninstall init-env openclaw-update-config \
	start stop restart \
	start-ollama stop-ollama restart-ollama \
	start-openclaw stop-openclaw restart-openclaw \
	start-mail stop-mail restart-mail \
	status logs-ollama logs-openclaw logs-mail \
	build rebuild sync-mails cleanup-inbound cleanup-inbound-dry transcribe-test

## 🎨 Colors
COLOR_RESET   = \033[0m
COLOR_INFO    = \033[32m
COLOR_COMMENT = \033[33m
COLOR_SECTION = \033[36m

## ⚙️ Services
MAKE_SUB     = $(MAKE) --no-print-directory
UID_GUI      := gui/$(shell id -u)
OLLAMA_LABEL := com.escarrie.ollama
OLLAMA_PLIST := $(HOME)/Library/LaunchAgents/$(OLLAMA_LABEL).plist

## 🆘 List help commands
help:
	printf "${COLOR_COMMENT}Usage:${COLOR_RESET}\n"
	printf "  make [commande]\n\n"
	printf "${COLOR_COMMENT}Commandes disponibles :${COLOR_RESET}\n"
	awk ' \
		BEGIN { section = "" } \
		/^\#\# \[.*\]/ { \
			section = substr($$0, 5, length($$0) - 5); \
			printf "\n${COLOR_SECTION}🧩  %s${COLOR_RESET}\n", section; \
			next; \
		} \
		/^\#\# [^[]/ { \
			desc = substr($$0, 4); \
			next; \
		} \
		/^[^.#][a-zA-Z0-9\-_\.@]+:/ { \
			cmd = substr($$1, 0, length($$1)-1); \
			printf "  ${COLOR_INFO}%-20s${COLOR_RESET} %s\n", cmd, desc; \
			desc = ""; \
		} \
	' COLOR_SECTION=$(COLOR_SECTION) COLOR_RESET=$(COLOR_RESET) COLOR_INFO=$(COLOR_INFO) $(MAKEFILE_LIST)

## [Installation]
## 📦 Install local dependencies (Homebrew, Ollama, models, OpenClaw, vault)
install:
	./scripts/install.sh

## 🧠 Install without downloading models
install-no-models:
	./scripts/install.sh --skip-models

## 🧹 Stop & uninstall project services (Ollama, OpenClaw, Docker, MCP) — keeps models and data
uninstall:
	./scripts/uninstall.sh

## 📝 Create .env file from .env.example if it doesn't exist
init-env:
	@if [ ! -f .env ]; then \
		cp .env.example .env; \
		echo ".env file created from .env.example"; \
	else \
		echo ".env file already exists"; \
	fi

## 🔄 Regenerate OpenClaw config + AGENTS.md from the repo, then restart the gateway
openclaw-update-config:
	./scripts/install.sh --skip-models --update-openclaw-config

## [Run — whole project]
## ▶️ Start the whole project (Ollama → OpenClaw → mail)
start:
	$(MAKE_SUB) start-ollama
	$(MAKE_SUB) start-openclaw
	$(MAKE_SUB) start-mail

## 🛑 Stop the whole project (mail → OpenClaw → Ollama)
stop:
	$(MAKE_SUB) stop-mail
	$(MAKE_SUB) stop-openclaw
	$(MAKE_SUB) stop-ollama

## 🔁 Restart the whole project
restart:
	$(MAKE_SUB) stop
	$(MAKE_SUB) start

## [Run — per service]
## ▶️ Start Ollama (LaunchAgent)
start-ollama:
	if launchctl print $(UID_GUI)/$(OLLAMA_LABEL) >/dev/null 2>&1; then \
		launchctl kickstart $(UID_GUI)/$(OLLAMA_LABEL); \
	else \
		test -f $(OLLAMA_PLIST) || { echo "LaunchAgent Ollama absente : lance make install"; exit 1; }; \
		launchctl bootstrap $(UID_GUI) $(OLLAMA_PLIST); \
	fi
	echo "Ollama démarré"

## 🛑 Stop Ollama (unloads the LaunchAgent, otherwise KeepAlive restarts it)
stop-ollama:
	if launchctl print $(UID_GUI)/$(OLLAMA_LABEL) >/dev/null 2>&1; then \
		launchctl bootout $(UID_GUI)/$(OLLAMA_LABEL); \
		for i in $$(seq 1 20); do \
			launchctl print $(UID_GUI)/$(OLLAMA_LABEL) >/dev/null 2>&1 || break; \
			sleep 0.5; \
		done; \
	fi
	echo "Ollama arrêté"

## 🔁 Restart Ollama
restart-ollama:
	$(MAKE_SUB) stop-ollama
	$(MAKE_SUB) start-ollama

## ▶️ Start the OpenClaw gateway
start-openclaw:
	openclaw gateway start

## 🛑 Stop the OpenClaw gateway
stop-openclaw:
	openclaw gateway stop

## 🔁 Restart the OpenClaw gateway
restart-openclaw:
	$(MAKE_SUB) stop-openclaw
	$(MAKE_SUB) start-openclaw

## ▶️ Start mail sync containers (mbsync + mail2md)
start-mail:
	docker compose up -d

## 🛑 Stop mail sync containers
stop-mail:
	docker compose down

## 🔁 Restart mail sync containers
restart-mail:
	$(MAKE_SUB) stop-mail
	$(MAKE_SUB) start-mail

## [Monitoring]
## 🩺 Show services status (Ollama, OpenClaw, mail)
status:
	printf "Ollama   : " && (curl -sf http://127.0.0.1:11434/api/version || echo "arrêté") && echo
	printf "Chargés  : " && (curl -sf http://127.0.0.1:11434/api/ps | jq -r '[.models[].name] | join(", ") | if . == "" then "aucun" else . end' || echo "-")
	launchctl list | grep -iE 'ollama|openclaw|inbound-cleanup' || echo "Aucune LaunchAgent du projet"
	openclaw gateway status || true
	docker compose ps

## 📜 Follow Ollama logs
logs-ollama:
	tail -f ~/Library/Logs/ollama.log

## 📜 Follow OpenClaw logs
logs-openclaw:
	openclaw logs --follow

## 📜 Follow mail containers logs
logs-mail:
	docker compose logs -f

## [Build]
## 🏗️ Build the mail docker images
build:
	docker compose build

## 🏗️ Rebuild the mail docker images without cache
rebuild:
	docker compose build --no-cache

## [Tools]
## 📨 Send saved mails to OpenClaw one by one, Telegram progress (MAILBOX= FOLDERS=INBOX SINCE=AAAA-MM-JJ LIMIT= EVERY=25)
sync-mails:
	docker compose run --rm \
		-e SYNC_MAILBOX="$(MAILBOX)" -e SYNC_FOLDERS="$(FOLDERS)" -e SYNC_SINCE="$(SINCE)" \
		-e SYNC_LIMIT="$(LIMIT)" -e SYNC_NOTIFY_EVERY="$(EVERY)" \
		mail2md python /app/mail2md.py sync

## 🧽 Delete received files (voice notes, images…) older than 24 h now
cleanup-inbound:
	./scripts/cleanup-inbound.sh

## 🔍 Show which received files would be deleted (dry run)
cleanup-inbound-dry:
	./scripts/cleanup-inbound.sh --dry-run

## 🎙️ Transcribe an audio file (make transcribe-test FILE=vocal.ogg)
transcribe-test:
	test -n "$(FILE)" || (echo "Usage : make transcribe-test FILE=vocal.ogg" && exit 1)
	time ./scripts/transcribe.sh "$(FILE)"
