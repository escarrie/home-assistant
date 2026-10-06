.DEFAULT_GOAL := help
.SILENT:
.PHONY: help check-tag build-prod push-prod build-push-prod

## 🎨 Colors
COLOR_RESET   = \033[0m
COLOR_INFO    = \033[32m
COLOR_COMMENT = \033[33m
COLOR_SECTION = \033[36m

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

## [Initialization]
## 📝 Create .env file from .env.example if it doesn't exist
init-env:
	@if [ ! -f .env ]; then \
		cp .env.example .env; \
		echo ".env file created from .env.example"; \
	else \
		echo ".env file already exists"; \
	fi

## [Build & Start]
## 🏗️ Build the services docker
build:
	docker compose build

## ▶️ Start the services in detached mode
start:
	docker compose up -d

## ▶️ Start the services in detached mode without using cache
start-no-cache:
	docker compose build --no-cache
	docker compose up -d