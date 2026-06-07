SHELL := /bin/bash
.ONESHELL:

ROOT := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
COMPOSE := docker compose --env-file env/das.env --env-file env/validator.env

.PHONY: help validate render up down ps logs doctor install upgrade rollback smoke prove-fast-confirm fetch-tls-aws setup-nginx-das chmod-scripts

help:
	@echo "Committee node commands:"
	@echo "  make validate      # validate env files and required inputs"
	@echo "  make render        # render compose config"
	@echo "  make up            # start services"
	@echo "  make down          # stop services"
	@echo "  make ps            # show service status"
	@echo "  make logs          # tail service logs"
	@echo "  make doctor        # run health checks"
	@echo "  make install       # validate + pull + up + doctor"
	@echo "  make upgrade       # backup + pull + up + doctor"
	@echo "  make rollback      # rollback to latest backup"
	@echo "  make smoke         # run smoke checks"
	@echo "  make prove-fast-confirm # prove fast confirmations are moving"
	@echo "  make fetch-tls-aws     # pull TLS PEMs from AWS Secrets Manager"
	@echo "  make setup-nginx-das   # install nginx site from env/das.network.env"

chmod-scripts:
	chmod +x scripts/*.sh checks/*.sh

validate: chmod-scripts
	./scripts/validate-env.sh

render:
	$(COMPOSE) config >/dev/null
	@echo "Compose render OK."

up:
	$(COMPOSE) up -d

down:
	$(COMPOSE) down

ps:
	$(COMPOSE) ps

logs:
	$(COMPOSE) logs --tail=200 -f

doctor: chmod-scripts
	./scripts/doctor.sh

install: chmod-scripts
	./scripts/install.sh

upgrade: chmod-scripts
	./scripts/upgrade.sh

rollback: chmod-scripts
	./scripts/rollback.sh

smoke: chmod-scripts
	./checks/smoke.sh

prove-fast-confirm: chmod-scripts
	./checks/prove-fast-confirmation.sh

fetch-tls-aws: chmod-scripts
	./scripts/fetch-tls-from-aws.sh

setup-nginx-das: chmod-scripts
	./scripts/setup-nginx-das.sh
