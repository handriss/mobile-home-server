# Phone Home Server — convenience wrapper around the scripts. See README.md.
#
#   make                 # list targets
#   make provision       # set up a NEW phone (do the manual prereqs first!)
#   make deploy SITE=./my-site
#   make run CMD='nginx -s reload'
#   make status
#
# Variables: SITE=<dir>  CMD='<shell cmd>'  PORT=8080  SERIAL=<adb-serial>

SHELL := /bin/bash
PORT  ?= 8080
SITE  ?= ./www
CMD   ?=
NTFY_TOPIC      ?=
HEALTHCHECK_URL ?=
NAME            ?=

# Target a specific device when several are attached:  make status SERIAL=XXXX
ifdef SERIAL
export ANDROID_SERIAL := $(SERIAL)
endif

# phone's LAN IP (auto-detected via adb)
phone_ip = $$(adb shell ip -f inet addr show wlan0 2>/dev/null | awk '/inet /{print $$2}' | cut -d/ -f1 | tr -d '\r')

.DEFAULT_GOAL := help
.PHONY: help provision monitor deploy run status restart reload update tunnel tunnel-stop ip

help: ## Show this help
	@echo "Phone Home Server — make targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[1;36m%-13s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Vars: SITE=<dir> (deploy)  CMD='<cmd>' (run)  PORT=$(PORT)  SERIAL=<adb-serial>"

provision: ## Provision a NEW phone (enable USB debugging + Wi-Fi + tap Allow first)
	./provision.sh --port $(PORT)

monitor: ## Install the battery monitor (optional: NTFY_TOPIC= HEALTHCHECK_URL= NAME=)
	NTFY_TOPIC='$(NTFY_TOPIC)' HEALTHCHECK_URL='$(HEALTHCHECK_URL)' NAME='$(NAME)' ./scripts/setup-monitor.sh

deploy: ## Deploy a site folder:  make deploy SITE=./my-site
	./scripts/deploy.sh $(SITE) $(PORT)

run: ## Run a command in Termux:  make run CMD='apt update && apt full-upgrade -y'
	@test -n "$(CMD)" || { echo "usage: make run CMD='<shell command>'"; exit 1; }
	./scripts/termux-run.sh '$(CMD)'

status: ## Show server status (HTTP code + page title)
	@ip=$(phone_ip); echo "phone: $$ip:$(PORT)"; \
	curl -s -o /dev/null -w "  HTTP %{http_code}\n" http://$$ip:$(PORT) || echo "  unreachable"; \
	curl -s -m6 http://$$ip:$(PORT)/ | grep -oE '<title>[^<]*</title>' || true

ip: ## Print the phone's LAN IP
	@echo $(phone_ip)

restart: ## Restart nginx on the phone
	./scripts/termux-run.sh 'nginx -s stop 2>/dev/null; nginx'

reload: ## Reload nginx config
	./scripts/termux-run.sh 'nginx -s reload'

update: ## Update Termux packages (nginx, cloudflared, ...)
	./scripts/termux-run.sh 'apt update && apt full-upgrade -y'

tunnel: ## Start a quick Cloudflare tunnel and print the public URL
	./scripts/termux-run.sh 'pkill cloudflared 2>/dev/null; cloudflared tunnel --url http://localhost:$(PORT) > ~/cf.log 2>&1 &'
	@sleep 10
	@./scripts/termux-run.sh 'grep -o "https://[a-z0-9-]*\.trycloudflare\.com" ~/cf.log | head -1 > $$PREFIX/share/nginx/html/_tunnel.txt' >/dev/null
	@sleep 2; ip=$(phone_ip); echo "public URL:"; curl -s http://$$ip:$(PORT)/_tunnel.txt; echo
	@ip=$(phone_ip); ./scripts/termux-run.sh "rm -f \$$PREFIX/share/nginx/html/_tunnel.txt" >/dev/null

tunnel-stop: ## Stop the Cloudflare tunnel
	./scripts/termux-run.sh 'pkill cloudflared'
